namespace GudangAtm.Api;

public record LoginRequest(string UserCode, string Password);

public class LoginUser
{
    public int UserId { get; set; }
    public string UserCode { get; set; } = "";
    public string? Name { get; set; }
    public int BplId { get; set; }
    public string? DefaultWhs { get; set; }
    public bool SuperUser { get; set; }
}

public record DocLine(
    string ItemCode,
    string? Uom,
    string? Brand,
    string? Origin,
    decimal Qty,
    decimal Qty2,
    decimal QtyPalet);

/// Inbound: header + baris detail (semua Flag 1). TrxCode IB/BT ditentukan server dari OWHS.External.
public record InboundRequest(
    string WhsCode,
    string NoMobil,
    string? ContainerNo,
    DateTime? DocDate,
    List<DocLine> Lines);

/// Outbound: Jenis OB / KR / RP.
///   OB -> ObjType 6710, TrxCode OB (atau BT bila warehouse titipan)
///   KR -> ObjType 6720, TrxCode KR (tidak boleh di warehouse titipan)
///   RP -> ObjType 6720, TrxCode RP (tidak boleh di warehouse titipan)
/// OutLines = palet keluar (Flag -1), InLines = Item Inbound (Flag 1, hanya KR/RP).
public record OutboundRequest(
    string WhsCode,
    string Jenis,
    string NoMobil,
    string? ContainerNo,
    DateTime? DocDate,
    List<DocLine> OutLines,
    List<DocLine>? InLines);

public record SavedDoc(string ObjType, long DocEntry, string TrxCode);

// Kelas baca-database memakai properti (bukan record) supaya Dapper bebas mengonversi tipe kolom
// (mis. smallint -> int, numeric -> decimal).
public class PalletSourceRow
{
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? Brand { get; set; }
    public string? Origin { get; set; }
    public string? ContainerNo { get; set; }
    public DateTime InboundDate { get; set; }
    public string WhsCode { get; set; } = "";
    public decimal Qty { get; set; }
    public decimal Qty2 { get; set; }
    public decimal QtyPalet { get; set; }
}

public class StockRow
{
    public decimal StockKg { get; set; }
    public decimal StockSak { get; set; }
    public decimal StockPalet { get; set; }
}

public class LabelLineRow
{
    public string ItemCode { get; set; } = "";
    public string ItemName { get; set; } = "";
    public string? Brand { get; set; }
    public decimal Qty { get; set; }
    public decimal Qty2 { get; set; }
    public decimal QtyPalet { get; set; }
}

public class DocHeaderRow
{
    public string ObjType { get; set; } = "";
    public long DocEntry { get; set; }
    public DateTime DocDate { get; set; }
    public string TrxCode { get; set; } = "";
    public string WhsCode { get; set; } = "";
    public string? NoMobil { get; set; }
    public string? ContainerNo { get; set; }
    public string? PtCode { get; set; }
    public string? PtName { get; set; }
    public string? DocStatus { get; set; }
}

public class StockCardRow
{
    public DateTime DocDate { get; set; }
    public string ObjType { get; set; } = "";
    public long DocEntry { get; set; }
    public string TrxCode { get; set; } = "";
    public string? ContainerNo { get; set; }
    public int Flag { get; set; }
    public decimal Kg { get; set; }
    public decimal Sak { get; set; }
    public decimal Palet { get; set; }
    public decimal SaldoKg { get; set; }
    public decimal SaldoSak { get; set; }
    public decimal SaldoPalet { get; set; }
}

// ---------------------------------------------------------------- CMS

public record CmsLineEdit(int LineNum, decimal Qty, decimal Qty2, decimal QtyPalet, string? NumAtCard);

/// Simpan perubahan Admin. TrxCode menentukan ObjType tujuan (SS = 6710, KR/RP = 6720).
public record CmsSaveRequest(
    string TrxCode,
    string? PtCode,
    string? CardCode,
    string? NumAtCard,
    string? BlNo,
    List<CmsLineEdit>? Lines);

public class CmsHeaderRow
{
    public string ObjType { get; set; } = "";
    public long DocEntry { get; set; }
    public DateTime DocDate { get; set; }
    public string TrxCode { get; set; } = "";
    public string WhsCode { get; set; } = "";
    public bool IsTitipan { get; set; }
    public string? PtCode { get; set; }
    public string? CardCode { get; set; }
    public string? CardType { get; set; }
    public string? NumAtCard { get; set; }
    public string? BlNo { get; set; }
    public string? DocStatus { get; set; }
}

public class CmsLineRow
{
    public int LineNum { get; set; }
    public string ItemCode { get; set; } = "";
    public int Flag { get; set; }
    public decimal Qty { get; set; }
    public decimal Qty2 { get; set; }
    public decimal QtyPalet { get; set; }
    public string? NumAtCard { get; set; }
}
