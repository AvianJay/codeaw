import { chromium } from '@playwright/test';
import { NativeDesktop } from '../dist/remote-desktop/native.js';

// A private browser profile and generated pixels: no user windows, input or images.
const browser = await chromium.launch({ headless: true });
try {
  for (const fps of [30, 60]) {
    const backend = new NativeDesktop('user');
    const page = await browser.newPage();
    let queue = Promise.resolve();
    let format;
    const errors = [];
    try {
      await page.exposeFunction('desktopNative', async (message) => {
        if (message.type === 'answer') await backend.request('answer', { sdp: message.sdp });
        if (message.type === 'candidate') await backend.request('candidate', { candidate: message.candidate, mid: message.mid });
      });
      await page.setContent('<video id="desktop" autoplay muted playsinline></video>');
      await page.evaluate(() => {
        const pc = new RTCPeerConnection({ iceServers: [] });
        window.desktopState = { decodedFrames: 0, width: 0, height: 0, fps: 0 };
        pc.ontrack = (event) => { document.querySelector('video').srcObject = event.streams[0]; };
        pc.onicecandidate = (event) => { if (event.candidate) void window.desktopNative({ type: 'candidate', candidate: event.candidate.candidate, mid: event.candidate.sdpMid }); };
        const candidates = [];
        window.desktopReceive = async (message) => {
          if (message.type === 'offer') {
            await pc.setRemoteDescription({ type: 'offer', sdp: message.sdp });
            for (const candidate of candidates.splice(0)) await pc.addIceCandidate(candidate);
            const answer = await pc.createAnswer(); await pc.setLocalDescription(answer);
            await window.desktopNative({ type: 'answer', sdp: answer.sdp });
          } else if (message.type === 'candidate') {
            const candidate = { candidate: message.candidate, sdpMid: message.mid, sdpMLineIndex: 0 };
            if (pc.remoteDescription) await pc.addIceCandidate(candidate); else candidates.push(candidate);
          }
        };
        window.desktopPoll = setInterval(async () => {
          for (const report of (await pc.getStats()).values()) {
            if (report.type === 'inbound-rtp' && report.kind === 'video') Object.assign(window.desktopState,
              { decodedFrames: report.framesDecoded ?? 0, width: report.frameWidth ?? 0, height: report.frameHeight ?? 0, fps: report.framesPerSecond ?? 0 });
          }
        }, 250);
      });
      backend.onEvent = (event) => {
        if (event.type === 'video-format') format = { fps: event.fps, hardware: event.hardware };
        if (event.type === 'video-error' || event.type === 'error') errors.push(event.type);
        if (event.type === 'offer' || event.type === 'candidate') queue = queue.then(() => page.evaluate((message) => window.desktopReceive(message), event));
      };
      await backend.request('videoTest', { fps });
      await page.waitForFunction(() => window.desktopState.decodedFrames >= 15, undefined, { timeout: 20_000 });
      await queue;
      const before = await page.evaluate(() => window.desktopState.decodedFrames);
      const start = Date.now(); await page.waitForTimeout(3000);
      const decoded = await page.evaluate(() => window.desktopState);
      const receivedFps = Math.round((decoded.decodedFrames - before) * 1000 / (Date.now() - start));
      if (decoded.width !== 640 || decoded.height !== 360 || errors.length) throw new Error('Synthetic WebRTC decoding failed');
      if (receivedFps < (format.fps ?? 30) * .8) throw new Error('Synthetic WebRTC frame rate below the selected mode');
      process.stdout.write(JSON.stringify({ requestedFps: fps, encoderFps: format.fps, hardware: format.hardware, receivedFps, decodedFrames: decoded.decodedFrames, width: decoded.width, height: decoded.height }) + '\n');
    } finally { await backend.dispose(); await page.close(); }
  }
} finally { await browser.close(); }
