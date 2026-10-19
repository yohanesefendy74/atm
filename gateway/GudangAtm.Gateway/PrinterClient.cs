using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

namespace GudangAtm.Gateway;

public static class PrinterClient
{
    public static async Task SendAsync(PrinterOptions p, string tspl)
    {
        var bytes = Encoding.Latin1.GetBytes(tspl);
        if (p.Mode.Equals("Tcp", StringComparison.OrdinalIgnoreCase))
        {
            using var c = new TcpClient();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
            await c.ConnectAsync(p.Host, p.Port, cts.Token);
            await c.GetStream().WriteAsync(bytes, cts.Token);
        }
        else
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException("Mode Windows hanya di Windows");
            RawPrinter.Send(p.NamaPrinter, bytes);
        }
    }
}

/// Kirim data mentah (RAW) ke printer Windows memakai spooler. Cocok untuk TSC USB dengan driver terpasang.
static class RawPrinter
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    class DOCINFO { [MarshalAs(UnmanagedType.LPWStr)] public string pDocName = "Label Gudang ATM"; [MarshalAs(UnmanagedType.LPWStr)] public string? pOutputFile; [MarshalAs(UnmanagedType.LPWStr)] public string pDataType = "RAW"; }

    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)] static extern bool OpenPrinter(string name, out IntPtr h, IntPtr d);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool ClosePrinter(IntPtr h);
    [DllImport("winspool.drv", CharSet = CharSet.Unicode, SetLastError = true)] static extern int StartDocPrinter(IntPtr h, int level, [In] DOCINFO di);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool EndDocPrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool StartPagePrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool EndPagePrinter(IntPtr h);
    [DllImport("winspool.drv", SetLastError = true)] static extern bool WritePrinter(IntPtr h, byte[] buf, int len, out int written);

    public static void Send(string printerName, byte[] data)
    {
        if (!OpenPrinter(printerName, out var h, IntPtr.Zero))
            throw new InvalidOperationException($"Printer '{printerName}' tidak ditemukan di Windows (kode {Marshal.GetLastWin32Error()})");
        try
        {
            if (StartDocPrinter(h, 1, new DOCINFO()) == 0) throw new InvalidOperationException($"StartDoc gagal ({Marshal.GetLastWin32Error()})");
            try
            {
                StartPagePrinter(h);
                if (!WritePrinter(h, data, data.Length, out var w) || w != data.Length)
                    throw new InvalidOperationException($"Kirim ke printer gagal ({Marshal.GetLastWin32Error()})");
                EndPagePrinter(h);
            }
            finally { EndDocPrinter(h); }
        }
        finally { ClosePrinter(h); }
    }
}
