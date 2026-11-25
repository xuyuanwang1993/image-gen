/**
 * 分割服务：一张图 -> 衣物 / 人物 / 皮肤 / 头发 / 背景 的 mask
 *
 * 模型：Xenova/segformer_b2_clothes（18 类，q8 量化约 29 MB）
 * 接口：
 *   GET  /health   -> {ok, model, ready}
 *   POST /segment  -> {"image": "<base64 png>"}
 *                   <- {width, height, ms, ratios:{...}, masks:{...base64 png...}}
 *
 * 只用 CPU，单张 640×1138 约 0.7~1s（模型加载首次 10s 左右）。
 */
import http from 'node:http';
import { pipeline, RawImage, env } from '@huggingface/transformers';
import { PNG } from 'pngjs';

const PORT = Number(process.env.SEGMENTER_PORT || 8000);
const MODEL = process.env.SEGMENT_MODEL || 'Xenova/segformer_b2_clothes';
const CACHE = process.env.MODEL_CACHE || '/models/segformer';

env.cacheDir = CACHE;
if (process.env.HF_ENDPOINT) {
  env.remoteHost = process.env.HF_ENDPOINT.replace(/\/+$/, '');
}

// 模型原始的 18 类（config.json 的 id2label）
const LABELS = [
  'Background', 'Hat', 'Hair', 'Sunglasses', 'Upper-clothes', 'Skirt', 'Pants', 'Dress',
  'Belt', 'Left-shoe', 'Right-shoe', 'Face', 'Left-leg', 'Right-leg', 'Left-arm', 'Right-arm',
  'Bag', 'Scarf',
];

// 按业务归并的桶。注意：模型的 18 类是互斥的，所以「皮肤」只有露出来的部分；
//「人物」是三个桶的并集（业务意义上的整个人）。
const BUCKETS = {
  hair: ['Hair'],
  skin: ['Face', 'Left-arm', 'Right-arm', 'Left-leg', 'Right-leg', 'Sunglasses'],
  upper: ['Upper-clothes'],
  lower: ['Pants', 'Skirt'],
  dress: ['Dress'],
  shoes: ['Left-shoe', 'Right-shoe'],
  // 配饰单独一组，换装时一般不想连包一起重绘
  accessory: ['Hat', 'Bag', 'Scarf', 'Belt'],
  garment: ['Upper-clothes', 'Skirt', 'Pants', 'Dress', 'Belt',
            'Left-shoe', 'Right-shoe', 'Scarf', 'Hat', 'Bag'],
  background: ['Background'],
};
const PERSON = ['hair', 'skin', 'garment'];

let segmenter = null;
let loading = null;

async function getSegmenter() {
  if (segmenter) return segmenter;
  if (!loading) {
    loading = (async () => {
      const t0 = Date.now();
      segmenter = await pipeline('image-segmentation', MODEL, { dtype: 'q8' });
      console.log(`[segmenter] model ready in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
      return segmenter;
    })();
  }
  return loading;
}

function decodePng(buffer) {
  const png = PNG.sync.read(buffer);
  const rgb = new Uint8ClampedArray(png.width * png.height * 3);
  for (let i = 0, j = 0; i < png.data.length; i += 4, j += 3) {
    rgb[j] = png.data[i];
    rgb[j + 1] = png.data[i + 1];
    rgb[j + 2] = png.data[i + 2];
  }
  return new RawImage(rgb, png.width, png.height, 3);
}

function encodeMask(mask, width, height) {
  const png = new PNG({ width, height });
  // 白色 + alpha 通道表示选区：前端直接 drawImage 就能正确叠加高亮
  for (let i = 0; i < width * height; i++) {
    const a = mask[i] ? 255 : 0;
    const o = i * 4;
    png.data[o] = 255;
    png.data[o + 1] = 255;
    png.data[o + 2] = 255;
    png.data[o + 3] = a;
  }
  return PNG.sync.write(png).toString('base64');
}

// 形态学：先膨胀再腐蚀（闭运算）补小洞，再外扩 1px 让重绘盖住边缘
function morph(mask, W, H, radius, grow) {
  const out = new Uint8Array(W * H);
  const r = radius;
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      // 膨胀：初始 0，邻域有 1 则置 1；腐蚀：初始 1，邻域有 0 则置 0
      let hit = grow ? 0 : 1;
      for (let dy = -r; dy <= r && !(grow && hit); dy++) {
        const yy = y + dy;
        if (yy < 0 || yy >= H) continue;
        for (let dx = -r; dx <= r; dx++) {
          const xx = x + dx;
          if (xx < 0 || xx >= W) continue;
          const v = mask[yy * W + xx];
          if (grow) { if (v) { hit = 1; break; } }
          else if (!v) { hit = 0; break; }
        }
      }
      out[y * W + x] = hit;
    }
  }
  return out;
}

function refine(mask, W, H) {
  let m = morph(mask, W, H, 1, true);      // dilate
  m = morph(m, W, H, 1, false);            // erode  -> 闭运算，补小洞
  m = morph(m, W, H, 1, true);             // 再外扩 1px
  return m;
}

async function segment(imageB64) {
  const seg = await getSegmenter();
  const img = decodePng(Buffer.from(imageB64, 'base64'));
  const W = img.width;
  const H = img.height;
  const total = W * H;

  const t0 = Date.now();
  const result = await seg(img, { ignore_labels: [] });
  const ms = Date.now() - t0;

  // 每像素一个类索引（0 = 未标注，LABELS[i] 对应 i+1）
  const labelMap = new Uint8Array(total);
  for (const item of result) {
    const idx = LABELS.indexOf(item.label);
    if (idx < 0) continue;
    const d = item.mask.data;
    const v = idx + 1;
    for (let p = 0; p < total; p++) if (d[p] > 0) labelMap[p] = v;
  }

  const masks = {};
  const ratios = {};
  const indexSets = {};

  for (const [name, labels] of Object.entries(BUCKETS)) {
    const set = new Set(labels.map((l) => LABELS.indexOf(l) + 1));
    indexSets[name] = set;
    const mask = new Uint8Array(total);
    let n = 0;
    for (let p = 0; p < total; p++) if (set.has(labelMap[p])) { mask[p] = 1; n++; }
    const cleaned = refine(mask, W, H);
    masks[name] = encodeMask(cleaned, W, H);
    ratios[name] = +((n / total) * 100).toFixed(1);
  }

  // 人物 = 头发 ∪ 皮肤 ∪ 衣物
  const personSet = new Set();
  for (const name of PERSON) indexSets[name].forEach((v) => personSet.add(v));
  const personMask = new Uint8Array(total);
  let pn = 0;
  for (let p = 0; p < total; p++) if (personSet.has(labelMap[p])) { personMask[p] = 1; pn++; }
  masks.person = encodeMask(refine(personMask, W, H), W, H);
  ratios.person = +((pn / total) * 100).toFixed(1);

  return { width: W, height: H, ms, ratios, masks };
}

function sendJson(res, code, payload) {
  const body = Buffer.from(JSON.stringify(payload));
  res.writeHead(code, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': body.length,
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function readBody(req, limit = 48 * 1024 * 1024) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > limit) {
        reject(new Error('图片太大（上限 48MB base64）'));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const path = (req.url || '').split('?')[0].replace(/\/+$/, '') || '/';

  if (req.method === 'GET' && path === '/health') {
    sendJson(res, 200, { ok: true, model: MODEL, ready: !!segmenter });
    return;
  }

  if (req.method === 'POST' && path === '/segment') {
    try {
      const raw = await readBody(req);
      const body = JSON.parse(raw.toString('utf8') || '{}');
      if (!body.image) {
        sendJson(res, 400, { error: '缺少 image（base64 png）' });
        return;
      }
      const out = await segment(body.image);
      sendJson(res, 200, out);
    } catch (err) {
      console.error('[segmenter] error:', err);
      sendJson(res, 500, { error: String(err && err.message ? err.message : err) });
    }
    return;
  }

  sendJson(res, 404, { error: 'not found' });
});

server.listen(PORT, '0.0.0.0', () => {
  console.log(`[segmenter] listening on :${PORT}, model=${MODEL}, cache=${CACHE}`);
  // 后台预热，别挡住 health
  getSegmenter().catch((e) => console.error('[segmenter] warmup failed:', e));
});
