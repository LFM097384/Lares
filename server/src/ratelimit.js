// 令牌桶限流(纯内存)。转写追加 / 密文中继 / 机器人 REST 共用。
//
// 为什么是令牌桶而不是滑动窗口计数:转写是「平时稀疏、偶尔一口气说完一串」的流量,
// 桶给突发留余量(burst),长期速率又被 refill 压住。

export class TokenBuckets {
  /**
   * @param {object} o
   * @param {number} o.capacity 桶容量(突发上限)
   * @param {number} o.perSec   每秒补充的令牌数
   */
  constructor({ capacity, perSec }) {
    this.capacity = capacity;
    this.perSec = perSec;
    this.buckets = new Map(); // key -> { tokens, at }
  }

  _fill(key, now) {
    let b = this.buckets.get(key);
    if (!b) {
      b = { tokens: this.capacity, at: now };
      this.buckets.set(key, b);
      return b;
    }
    const add = ((now - b.at) / 1000) * this.perSec;
    b.tokens = Math.min(this.capacity, b.tokens + add);
    b.at = now;
    return b;
  }

  /// 取一个令牌。成功返回 0;失败返回需要等待的毫秒数(>0)。
  take(key, n = 1, now = Date.now()) {
    const b = this._fill(key, now);
    if (b.tokens >= n) {
      b.tokens -= n;
      return 0;
    }
    const lack = n - b.tokens;
    return Math.max(1, Math.ceil((lack / this.perSec) * 1000));
  }

  /// 清掉已经补满的桶,防止 key 无限增长
  sweep(now = Date.now()) {
    for (const [k, b] of this.buckets) {
      const add = ((now - b.at) / 1000) * this.perSec;
      if (b.tokens + add >= this.capacity) this.buckets.delete(k);
    }
  }

  delete(key) { this.buckets.delete(key); }
}
