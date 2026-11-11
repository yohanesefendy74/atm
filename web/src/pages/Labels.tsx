import { useMemo, useState } from 'react';
import { ApiError, get, type Row } from '../api';
import { ErrorBox, Icon, Page, Spinner, fmt, fmtDate, isInbound, useLoad } from '../ui';
import { qrSvgPath } from '../qr';

type LabelItem = { ptName?: string | null; itemCode: string; itemName: string; brand: string | null; kodeRuangan?: string | null; containerNo?: string | null; packKg: number; sakPerPalet: number; qtyPalet: number; qr: string };

const contDisplay = (c: string | null) => {
  const s = (c ?? '').replace(/\s/g, '');
  return s.length === 11 ? `${s.slice(0, 4)} ${s.slice(4)}` : s;
};

function QrSvg({ text }: { text: string }) {
  const { size, d } = useMemo(() => qrSvgPath(text, 1), [text]);
  return (
    <svg viewBox={`0 0 ${size} ${size}`} shapeRendering="crispEdges" role="img" aria-label={`QR ${text}`}>
      <rect width={size} height={size} fill="#fff" />
      <path d={d} fill="#16191d" />
    </svg>
  );
}

/** Label palet 100 × 70 mm: container besar, tanggal, item, merek, @isi, PT (OPRC.PrcName), QR, kotak SAK. */
function Label({ head, item }: { head: Row; item: LabelItem }) {
  return (
    <div className="plabel">
      <div className="l">
        <div className="cont">{contDisplay(item.containerNo ?? head.containerNo)}</div>
        <div>{fmtDate(head.docDate)}</div>
        <div>{item.itemName}</div>
        <div>{item.brand ?? ''}</div>
        <div>@{fmt(item.packKg)}</div>
        <div>{item.ptName ?? head.ptName}</div>
        {item.kodeRuangan && <div><strong>RUANG {item.kodeRuangan}</strong></div>}
        <div className="qrtext">{item.qr}</div>
      </div>
      <div className="r">
        <QrSvg text={item.qr} />
        <div className="box">{fmt(item.sakPerPalet)} SAK</div>
        <div className="box" />
        <div className="box" />
      </div>
    </div>
  );
}

export default function LabelPrint({ objType, docEntry }: { objType: string; docEntry: string }) {
  const isIn = isInbound(objType);
  return (
    <LabelSheet
      url={`/api/labels/${encodeURIComponent(objType)}/${encodeURIComponent(docEntry)}`}
      title={docEntry}
      eyebrow={isIn ? 'Label QR · PT dari Admin' : 'Label Item Inbound · PT dari Admin'}
      backTo={isIn ? '/inbound' : '/outbound'}
      accent={isIn ? 'in' : 'out'}
    />
  );
}

/** Label palet SPBB: disiapkan Admin sebelum barang datang (lot = nomor SPBB). */
export function PlanLabelPrint({ planId }: { planId: string }) {
  return <LabelSheet url={`/api/cms/plan/${encodeURIComponent(planId)}/labels`} title="Label QR SPBB" eyebrow="Admin · label disiapkan sebelum barang datang" backTo={`/admin/plan/${planId}`} accent="in" />;
}

function LabelSheet({ url, title, eyebrow, backTo, accent }: { url: string; title: string; eyebrow: string; backTo: string; accent: 'in' | 'out' }) {
  const { data, error, reload } = useLoad(() => get<Row>(url), [url]);
  const [pick, setPick] = useState(0);
  const items: LabelItem[] = (data?.items as LabelItem[]) ?? [];
  const total = items.reduce((s, i) => s + i.qtyPalet, 0);
  const locked = error instanceof ApiError && error.status === 409;

  return (
    <Page
      eyebrow={eyebrow}
      title={(data?.planNo as string) ?? title}
      accent={accent}
      backTo={backTo}
      narrow
      footerNote="Printer label diatur di dialog cetak browser: ukuran kertas 100 × 70 mm, margin 0."
      footer={
        items.length > 0 ? (
          <button className="btn" onClick={() => window.print()}>
            <Icon name="print" /> Cetak semua {total} label
          </button>
        ) : undefined
      }
    >
      {locked ? (
        <div className="card stack">
          <div className="row">
            <Icon name="lock" /> <strong>Label terkunci</strong>
          </div>
          <div>{errorMessage(error)}</div>
          <button className="btn small ghost" onClick={reload}>
            Cek lagi
          </button>
        </div>
      ) : error !== null ? (
        <ErrorBox error={error} onRetry={reload} />
      ) : !data ? (
        <Spinner />
      ) : (
        <>
          <div className="card noprint">{items[pick] && <Label head={data} item={items[pick]} />}</div>
          <table className="table noprint">
            <thead>
              <tr>
                <th>Item</th>
                <th className="num">Label = Qty Palet</th>
              </tr>
            </thead>
            <tbody>
              {items.map((i, idx) => (
                <tr key={`${i.itemCode}-${idx}`} className="click" onClick={() => setPick(idx)} aria-selected={idx === pick}>
                  <td>
                    <span className="mono">
                      <strong>{i.itemCode}</strong>
                    </span>
                    <br />
                    <span className="small muted">{i.itemName}</span>
                    <div className="small mono">{i.qr}</div>
                  </td>
                  <td className="num">{i.qtyPalet} label</td>
                </tr>
              ))}
              <tr>
                <td>
                  <strong>Total</strong>
                </td>
                <td className="num">
                  <strong>{total} label</strong>
                </td>
              </tr>
            </tbody>
          </table>
          <p className="hint noprint">Untuk cetak lewat Bluetooth langsung ke printer TSC/Xprinter, gunakan aplikasi HP Gudang ATM.</p>
          <div className="printonly" aria-hidden="true">
            {items.flatMap((i, k) => Array.from({ length: i.qtyPalet }, (_, n) => <Label key={`${k}-${n}`} head={data} item={i} />))}
          </div>
        </>
      )}
    </Page>
  );
}

const errorMessage = (e: unknown) => (e instanceof Error ? e.message : String(e));
