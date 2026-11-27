/* Gudang ATM - CEK database ERP (hanya membaca, tidak mengubah apa pun).
   Jalankan di SSMS pada database ERP TUJUAN sebelum API diarahkan ke sana, dan sekali lagi sesudah data gudang dipindahkan.
   Hasil: setiap baris yang muncul = masalah yang perlu dibereskan. Semua kosong / 0 = siap.

   Bagian 1  Tabel & kolom ERP yang dibaca / ditulis aplikasi
   Bagian 2  Objek Gudang ATM (tabel WHS_*, prosedur, view) sudah dibuat?
   Bagian 3  Data gudang yang merujuk master ERP (user, gudang, item, PT, customer, dokumen sumber) masih cocok?
*/
SET NOCOUNT ON;
PRINT '== Database: ' + DB_NAME();

/* ---------------------------------------------------------------- 1. tabel & kolom ERP */
DECLARE @k TABLE (T SYSNAME, C SYSNAME);
INSERT @k VALUES
 ('OUSR','USERID'),('OUSR','USER_CODE'),('OUSR','U_NAME'),('OUSR','password'),('OUSR','Branch'),('OUSR','Fax'),('OUSR','SUPERUSER'),
 ('USR9','UserId'),('USR9','WhsCode'),
 ('OWHS','WhsCode'),('OWHS','WhsName'),('OWHS','State'),('OWHS','Country'),('OWHS','External'),('OWHS','BPLid'),
 ('OCST','Code'),('OCST','Name'),('OCST','Country'),
 ('OITM','ItemCode'),('OITM','ItemName'),('OITM','InvntryUom'),('OITM','ItmsGrpCod'),('OITB','ItmsGrpCod'),('OITB','ItmsGrpNam'),
 ('OPRC','PrcCode'),('OPRC','PrcName'),
 ('OCRD','CardCode'),('OCRD','CardName'),('OCRD','CardType'),
 ('SYS_GCM','CONDITION'),
 -- dokumen sumber: header
 ('OPBL','DocEntry'),('OPBL','DocNum'),('OPBL','CardCode'),('OPBL','CardName'),('OPBL','DocDate'),('OPBL','NumAtCard'),('OPBL','CANCELED'),('OPBL','DocStatus'),('OPBL','DocType'),('OPBL','BPLId'),('OPBL','U_IDU_KODE_PT'),
 ('ODLN','DocEntry'),('ODLN','DocNum'),('ODLN','CardCode'),('ODLN','CardName'),('ODLN','DocDate'),('ODLN','NumAtCard'),('ODLN','CANCELED'),('ODLN','DocStatus'),('ODLN','DocType'),('ODLN','BPLId'),('ODLN','U_IDU_KODE_PT'),
 ('ORDR','DocEntry'),('ORDR','DocNum'),('ORDR','CardCode'),('ORDR','CardName'),('ORDR','DocDate'),('ORDR','NumAtCard'),('ORDR','CANCELED'),('ORDR','DocStatus'),('ORDR','DocType'),('ORDR','BPLId'),
 -- dokumen sumber: baris
 ('PBL1','DocEntry'),('PBL1','LineNum'),('PBL1','ItemCode'),('PBL1','Dscription'),('PBL1','Quantity'),('PBL1','OpenQty'),('PBL1','U_IDU_QtyPack'),('PBL1','FreeTxt'),
 ('PBL1','ShipToCode'),('PBL1','StgDesc'),('PBL1','SerialNum'),('PBL1','BaseAtCard'),('PBL1','BlockNum'),
 ('DLN1','DocEntry'),('DLN1','LineNum'),('DLN1','ItemCode'),('DLN1','Dscription'),('DLN1','Quantity'),('DLN1','OpenQty'),('DLN1','U_IDU_QtyPack'),('DLN1','FreeTxt'),
 ('DLN1','ShipToCode'),('DLN1','StgDesc'),('DLN1','SerialNum'),('DLN1','BaseAtCard'),('DLN1','BlockNum'),
 ('RDR1','DocEntry'),('RDR1','LineNum'),('RDR1','ItemCode'),('RDR1','Dscription'),('RDR1','Quantity'),('RDR1','OpenQty'),('RDR1','U_IDU_QtyPack'),('RDR1','FreeTxt'),('RDR1','WhsCode'),
 -- dokumen gudang krani (dibuat aplikasi)
 ('OKRN','ObjType'),('OKRN','DocEntry'),('OKRN','DocDate'),('OKRN','BPLId'),('OKRN','WhsCode'),('OKRN','UserId'),('OKRN','TrxCode'),('OKRN','DocStatus'),('OKRN','U_IDU_Kode_PT'),
 ('KRN1','ObjType'),('KRN1','DocEntry'),('KRN1','LineNum'),('KRN1','ItemCode'),('KRN1','qty'),('KRN1','Qty2'),('KRN1','QtyPalet'),('KRN1','flags'),('KRN1','LineStatus'),('KRN1','brand_name');

SELECT '1. KOLOM ERP TIDAK ADA' AS Cek, k.T AS Tabel, k.C AS Kolom
FROM @k k WHERE COL_LENGTH('dbo.' + k.T, k.C) IS NULL
ORDER BY k.T, k.C;

/* ---------------------------------------------------------------- 2. objek Gudang ATM */
DECLARE @o TABLE (N SYSNAME, Skrip NVARCHAR(60));
INSERT @o VALUES
 ('WHS_AuditLog','web_security.sql'),('usp_WHS_NextDocEntry','gudang_atm_relasi.sql bagian 6'),
 ('WHS_Plan','gudang_atm_v2_struktur.sql'),('WHS_Plan1','gudang_atm_v2_struktur.sql'),('WHS_MasterRuangan','gudang_atm_v2_struktur.sql'),
 ('WHS_Kendaraan','gudang_atm_v2_struktur.sql'),('WHS_Gateway','gateway.sql'),
 ('WHS_ItemScrap','gudang_atm_v2_tambahan.sql'),('WHS_SuratJalan','gudang_atm_v2_tambahan.sql'),('WHS_Opname','gudang_atm_v2_tambahan.sql'),
 ('vw_WHS_PlanAlokasi','gudang_atm_v2_tambahan.sql'),('TR_KRN1_OpnameTahan','gudang_atm_v2_tambahan.sql'),
 ('WHS_Saldo','saldo.sql'),('usp_WHS_SaldoPosting','saldo.sql'),('usp_WHS_SaldoRebuild','saldo.sql'),('vw_WHS_SaldoSelisih','saldo.sql');
SELECT '2. OBJEK GUDANG ATM BELUM ADA' AS Cek, N AS Objek, Skrip AS JalankanSkrip FROM @o WHERE OBJECT_ID('dbo.' + N) IS NULL;

SELECT '2. HAK gudang_app' AS Cek,
       CASE WHEN DATABASE_PRINCIPAL_ID('gudang_app') IS NULL THEN 'user gudang_app BELUM dibuat di database ini' ELSE 'ada' END AS Status;

/* ---------------------------------------------------------------- 3. data gudang vs master ERP */
IF OBJECT_ID('dbo.WHS_MasterRuangan') IS NOT NULL
    EXEC(N'SELECT ''3. RUANGAN: kode gudang tidak ada di OWHS'' AS Cek, r.KodeRuangan, r.WhsCode
           FROM WHS_MasterRuangan r WHERE NOT EXISTS (SELECT 1 FROM OWHS w WHERE w.WhsCode = r.WhsCode)');

EXEC(N'SELECT ''3. GUDANG TANPA STATE (tidak bisa berbagi pos/kendaraan satu area)'' AS Cek, w.WhsCode, w.WhsName
       FROM OWHS w WHERE ISNULL(w.State, '''') = '''' AND EXISTS (SELECT 1 FROM USR9 a WHERE a.WhsCode = w.WhsCode)');

IF OBJECT_ID('dbo.WHS_PlanKrani') IS NOT NULL
    EXEC(N'SELECT ''3. KRANI di rencana tidak ada di OUSR'' AS Cek, k.PlanId, k.UserId
           FROM WHS_PlanKrani k WHERE NOT EXISTS (SELECT 1 FROM OUSR u WHERE u.USERID = k.UserId)');

EXEC(N'SELECT ''3. USER dokumen gudang tidak ada di OUSR'' AS Cek, h.UserId, COUNT(*) AS Dokumen
       FROM OKRN h WHERE h.UserId IS NOT NULL AND NOT EXISTS (SELECT 1 FROM OUSR u WHERE u.USERID = h.UserId) GROUP BY h.UserId');

EXEC(N'SELECT ''3. GUDANG dokumen gudang tidak ada di OWHS'' AS Cek, h.WhsCode, COUNT(*) AS Dokumen
       FROM OKRN h WHERE NOT EXISTS (SELECT 1 FROM OWHS w WHERE w.WhsCode = h.WhsCode) GROUP BY h.WhsCode');

EXEC(N'SELECT ''3. ITEM di dokumen gudang tidak ada di OITM'' AS Cek, d.ItemCode, COUNT(*) AS Baris
       FROM KRN1 d WHERE NOT EXISTS (SELECT 1 FROM OITM i WHERE i.ItemCode = d.ItemCode) GROUP BY d.ItemCode');

IF COL_LENGTH('dbo.KRN1', 'U_IDU_Kode_PT') IS NOT NULL
    EXEC(N'SELECT ''3. PT di dokumen gudang tidak ada di OPRC'' AS Cek, d.U_IDU_Kode_PT AS PtCode, COUNT(*) AS Baris
           FROM KRN1 d WHERE ISNULL(d.U_IDU_Kode_PT, '''') <> '''' AND NOT EXISTS (SELECT 1 FROM OPRC p WHERE p.PrcCode = d.U_IDU_Kode_PT) GROUP BY d.U_IDU_Kode_PT');

IF OBJECT_ID('dbo.WHS_ItemScrap') IS NOT NULL
    EXEC(N'SELECT ''3. ITEM SCRAP tidak ada di OITM'' AS Cek, s.ItemCode FROM WHS_ItemScrap s WHERE NOT EXISTS (SELECT 1 FROM OITM i WHERE i.ItemCode = s.ItemCode)');

IF OBJECT_ID('dbo.WHS_Plan') IS NOT NULL
BEGIN
    EXEC(N'SELECT ''3. CUSTOMER/SUPPLIER rencana tidak ada di OCRD'' AS Cek, p.PlanNo, p.CardCode
           FROM WHS_Plan p WHERE p.Status NOT IN (''Batal'',''Selesai'',''SelesaiKurang'') AND ISNULL(p.CardCode, '''') <> ''''
             AND NOT EXISTS (SELECT 1 FROM OCRD c WHERE c.CardCode = p.CardCode)');
    -- rencana yang masih berjalan harus menunjuk baris dokumen ERP yang SAMA (DocEntry & LineNum sama, item sama)
    EXEC(N'SELECT ''3. RENCANA AKTIF: baris dokumen ERP sumber tidak cocok'' AS Cek, p.PlanNo, l.BaseType, l.BaseDocEntry, l.BaseLineNum, l.ItemCode,
                  CASE WHEN x.ItemCode IS NULL THEN ''baris tidak ada'' WHEN x.ItemCode <> l.ItemCode THEN ''item beda: '' + x.ItemCode ELSE ''dokumen tidak open'' END AS Masalah
           FROM WHS_Plan p JOIN WHS_Plan1 l ON l.PlanId = p.PlanId
           OUTER APPLY (
               SELECT d.ItemCode, h.DocStatus FROM PBL1 d JOIN OPBL h ON h.DocEntry = d.DocEntry WHERE l.BaseType = ''BL'' AND d.DocEntry = l.BaseDocEntry AND d.LineNum = l.BaseLineNum
               UNION ALL SELECT d.ItemCode, h.DocStatus FROM DLN1 d JOIN ODLN h ON h.DocEntry = d.DocEntry WHERE l.BaseType = ''DO'' AND d.DocEntry = l.BaseDocEntry AND d.LineNum = l.BaseLineNum
               UNION ALL SELECT d.ItemCode, h.DocStatus FROM RDR1 d JOIN ORDR h ON h.DocEntry = d.DocEntry WHERE l.BaseType = ''SO'' AND d.DocEntry = l.BaseDocEntry AND d.LineNum = l.BaseLineNum
           ) x
           WHERE p.Status IN (''Draft'',''Terbit'',''Proses'',''Partial'') AND l.BaseType IN (''BL'',''DO'',''SO'')
             AND (x.ItemCode IS NULL OR x.ItemCode <> l.ItemCode OR x.DocStatus <> ''O'')');
END

IF OBJECT_ID('dbo.vw_WHS_SaldoSelisih') IS NOT NULL
    EXEC(N'SELECT ''3. SALDO berbeda dengan dokumen (jalankan EXEC dbo.usp_WHS_SaldoRebuild)'' AS Cek, COUNT(*) AS Baris FROM vw_WHS_SaldoSelisih HAVING COUNT(*) > 0');

PRINT '== Selesai. Semua hasil kosong = siap.';
