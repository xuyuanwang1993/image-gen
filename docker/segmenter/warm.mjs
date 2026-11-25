/** 预热：把模型下载到 cacheDir（prepare.sh 会调它，避免第一次点「自动选区」等太久） */
import { pipeline, env } from '@huggingface/transformers';

const MODEL = process.env.SEGMENT_MODEL || 'Xenova/segformer_b2_clothes';
env.cacheDir = process.env.MODEL_CACHE || '/models/segformer';
if (process.env.HF_ENDPOINT) env.remoteHost = process.env.HF_ENDPOINT.replace(/\/+$/, '');

const t0 = Date.now();
await pipeline('image-segmentation', MODEL, { dtype: 'q8' });
console.log(`[warm] model ready in ${((Date.now() - t0) / 1000).toFixed(1)}s`);
