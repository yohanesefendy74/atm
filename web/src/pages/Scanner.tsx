import { useEffect, useRef, useState } from 'react';

// Kamera + BarcodeDetector (Chrome Android / Edge). Bila tidak didukung, krani tetap bisa memakai
// scanner barcode USB/Bluetooth (mengetik ke kolom input) atau mengetik QR manual.
type Detector = { detect: (src: CanvasImageSource) => Promise<{ rawValue: string }[]> };
declare global {
  interface Window {
    BarcodeDetector?: new (opts: { formats: string[] }) => Detector;
  }
}

export const cameraScanSupported = () => typeof window !== 'undefined' && !!window.BarcodeDetector && !!navigator.mediaDevices?.getUserMedia;

export default function Scanner({ armed, onScan, message }: { armed: boolean; onScan: (text: string) => void; message: string }) {
  const video = useRef<HTMLVideoElement>(null);
  const [err, setErr] = useState('');
  const armedRef = useRef(armed);
  armedRef.current = armed;
  const cb = useRef(onScan);
  cb.current = onScan;

  useEffect(() => {
    if (!cameraScanSupported()) return;
    let stream: MediaStream | null = null;
    let timer = 0;
    let stopped = false;
    const detector = new window.BarcodeDetector!({ formats: ['qr_code'] });
    navigator.mediaDevices
      .getUserMedia({ video: { facingMode: 'environment' }, audio: false })
      .then((s) => {
        if (stopped) {
          s.getTracks().forEach((t) => t.stop());
          return;
        }
        stream = s;
        if (video.current) {
          video.current.srcObject = s;
          void video.current.play();
        }
        timer = window.setInterval(async () => {
          if (!armedRef.current || !video.current || video.current.readyState < 2) return;
          try {
            const codes = await detector.detect(video.current);
            if (codes.length && armedRef.current) {
              armedRef.current = false;
              cb.current(codes[0].rawValue);
            }
          } catch {
            /* frame belum siap */
          }
        }, 300);
      })
      .catch(() => setErr('Kamera tidak bisa dibuka. Izinkan akses kamera atau pakai input QR di bawah.'));
    return () => {
      stopped = true;
      window.clearInterval(timer);
      stream?.getTracks().forEach((t) => t.stop());
    };
  }, []);

  if (!cameraScanSupported()) return null;
  return (
    <div className="scanner noprint">
      <video ref={video} muted playsInline aria-label="Kamera scan QR" />
      <div className="frame" />
      <div className="msg">{err || message}</div>
    </div>
  );
}
