namespace GudangAtm.Gateway;

public class ApiOptions
{
    public string BaseUrl { get; set; } = "";
    public string GatewayId { get; set; } = "";
    public string Key { get; set; } = "";          // diisi lewat environment: Api__Key (jangan di file / Git)
    public bool TrustSelfSigned { get; set; }
}

public class ScaleOptions
{
    public string Kode { get; set; } = "";
    public string Port { get; set; } = "COM1";
    public int Baud { get; set; } = 9600;
    public int DataBits { get; set; } = 8;
    public string Parity { get; set; } = "None";   // None, Even, Odd, Mark, Space
    public string StopBits { get; set; } = "One";  // One, Two, OnePointFive
    /// Regex pengambil angka berat dari satu baris data. Grup 1 dipakai bila ada, jika tidak seluruh kecocokan.
    public string Pattern { get; set; } = @"[-+]?\d+(?:[.,]\d+)?";
    public string Satuan { get; set; } = "kg";     // kg atau g (g dibagi 1000)
    /// Regex penanda "stabil" pada baris (mis. "ST" atau "S "). Kosong = stabil bila beberapa pembacaan berturut-turut sama.
    public string StabilPattern { get; set; } = "";
    /// Teks yang dikirim ke indikator sebelum membaca (bila indikator tidak mengirim data terus-menerus). Mendukung \r \n.
    public string PerintahMinta { get; set; } = "";
    public int MinStabil { get; set; } = 3;
}

public class PrinterOptions
{
    public string Kode { get; set; } = "";
    public string Mode { get; set; } = "Windows";  // Windows (driver TSC/USB, kirim RAW) atau Tcp (port 9100)
    public string NamaPrinter { get; set; } = "";
    public string Host { get; set; } = "";
    public int Port { get; set; } = 9100;
}
