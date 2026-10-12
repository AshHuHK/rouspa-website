import { Component } from 'react';
import { publicWebsiteUrl } from './lib/native-platform.js';
import './application-recovery.css';

export class ApplicationBoundary extends Component {
  state = { failed: false };
  static getDerivedStateFromError() { return { failed: true }; }
  render() {
    if (!this.state.failed) return this.props.children;
    return <main className="application-recovery" role="alert">
      <p>ROU SPA · 柔療髮浴</p><h1>頁面暫時無法顯示</h1>
      <p>可能是網路中斷或網站剛完成更新。請重新載入目前頁面；若剛才正在提交或收款，先核對紀錄再重試。</p>
      <div><button type="button" onClick={() => window.location.reload()}>重新載入頁面</button><a href={publicWebsiteUrl('/')}>返回官網首頁</a></div>
    </main>;
  }
}
