/* 任务结果缓存（最多 12 条）+ 双击放大看原图，生图页 / 流程图页共用。
 *
 * 用法：
 *   const cache = new ResultCache();          // 上限见 MAX_RESULTS
 *   cache.add({url, name, label, meta});      // 超出的最老一条会被回收（revokeObjectURL）
 *   cache.items                               // 旧 -> 新
 *   Lightbox.open(entry) / Lightbox.close()
 */
const MAX_RESULTS = 12;  // 最多缓存 12 次任务结果

class ResultCache {
  constructor(max = MAX_RESULTS) {
    this.max = max;
    this.items = [];
  }

  /** 加入一条结果；返回被淘汰的条目数组（调用方据此清理 DOM） */
  add(entry) {
    this.items.push(entry);
    const evicted = [];
    while (this.items.length > this.max) {
      const old = this.items.shift();
      this._release(old);
      evicted.push(old);
    }
    return evicted;
  }

  get latest() {
    return this.items[this.items.length - 1] || null;
  }

  clear() {
    this.items.forEach(e => this._release(e));
    this.items = [];
  }

  /** 删除单条；返回是否删掉了。会 revoke blob URL。 */
  remove(entry) {
    const i = this.items.indexOf(entry);
    if (i < 0) return false;
    this.items.splice(i, 1);
    this._release(entry);
    return true;
  }

  _release(entry) {
    if (entry && typeof entry.url === 'string' && entry.url.startsWith('blob:')) {
      URL.revokeObjectURL(entry.url);   // 及时释放，避免内存越攒越多
    }
  }
}

const Lightbox = (() => {
  let root = null, img = null, caption = null, download = null, openTab = null, current = null;

  function build() {
    if (root) return;
    root = document.createElement('div');
    root.className = 'lightbox';
    root.innerHTML = `
      <div class="bar">
        <strong>原图</strong>
        <span class="grow"></span>
        <a target="_blank" rel="noreferrer">新标签打开</a>
        <a download>下载</a>
        <button type="button">关闭 (Esc)</button>
      </div>
      <img alt="原图">
      <div class="tip">按原始像素显示 · 滚轮/滚动条查看全图 · 双击背景或按 Esc 关闭</div>`;
    document.body.appendChild(root);
    img = root.querySelector('img');
    caption = root.querySelector('.grow');
    openTab = root.querySelector('.bar a[target]');
    download = root.querySelector('.bar a[download]');
    root.querySelector('button').onclick = close;
    root.addEventListener('click', e => { if (e.target === root) close(); });
    document.addEventListener('keydown', e => { if (e.key === 'Escape') close(); });
  }

  function open(entry) {
    if (!entry || !entry.url) return;
    build();
    current = entry;
    img.src = entry.url;
    img.alt = entry.name || '原图';
    caption.textContent = [entry.name, entry.label, entry.meta]
      .filter(Boolean).join(' · ');
    openTab.href = entry.url;
    download.href = entry.url;
    download.download = entry.name || 'result';
    root.classList.add('on');
    root.scrollTop = 0;
    // 显示真实像素尺寸
    img.onload = () => {
      const dim = `${img.naturalWidth}×${img.naturalHeight}px`;
      caption.textContent = [entry.name, dim, entry.meta].filter(Boolean).join(' · ');
    };
  }

  function close() {
    if (!root) return;
    root.classList.remove('on');
    img.removeAttribute('src');
    current = null;
  }

  return { open, close };
})();
