# Status implementasi (19 Okt 2026)

| Area | Desain (`design/`) | Kode | Catatan |
|---|---|---|---|
| Login, Beranda, Inbound/Outbound krani, Laporan | ya | **v1 ada** (`api/`, `web/`, `app/`) | belum diuji terhadap database asli |
| CMS cek input krani & posting | ya | **v1 ada** | kolom bertanda ASUMSI di `Sql.cs` perlu dicocokkan |
| SPBB dari BL/DO, SPMB dari SO (1 SPMB = 1 customer), partial & outstanding | ya | belum | tabel di `gudang_atm_v2_struktur.sql` |
| Kode customer titipan; tanda titipan per **ruangan**; titipan ≠ non-titipan tidak boleh dicampur | ya | belum | v1 masih membaca titipan dari `OWHS.External` (per warehouse) |
| Master Warehouse & Ruangan (tabel sendiri `WHS_MasterRuangan`), master palet, timbangan palet >1 | ya | belum | |
| Registrasi kendaraan & timbang (pos), riwayat berat mobil/kontainer kosong | ya | belum | butuh akses LAN ke indikator timbangan |
| Setup batas toleransi (susut, koreksi, repack, timbang, kecepatan bongkar/muat, jam kerja) | ya | belum | `WHS_Setup` |
| Jadwal bongkar muat (ETA, jalur, durasi) | ya | belum | `WHS_MasterDock`, kolom jadwal di `WHS_Plan` |
| Surat Jalan (beberapa SPMB dalam satu surat, beda customer boleh; hanya di Gudang ATM) | ya | belum | `WHS_SuratJalan*` |
| Penyesuaian (KR/SS), Repacking (RP) | ya | v1 sebagian | aturan ruangan titipan belum di kode |

Urutan pengerjaan kode yang disarankan: (1) tabel + Setup, (2) SPBB/SPMB + titipan, (3) registrasi & timbang, (4) krani (scan sesuai dokumen),
(5) Jadwal, (6) Surat Jalan, (7) riwayat berat & laporan.
Pertanyaan yang masih terbuka ada di percakapan desain; tanyakan sebelum tahap 1.


**Gateway alat (timbangan RS232, printer TSC):** API (`GatewayEndpoints.cs`), `database/gateway.sql`, dan `gateway/` sudah ditulis, belum dikompilasi/diuji. Lihat `GATEWAY.md`. Format data timbangan menunggu hasil `--sniff`.
