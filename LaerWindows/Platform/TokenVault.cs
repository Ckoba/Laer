using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;
using Laer.Windows.Core;

namespace Laer.Windows;

// DPAPI CurrentUser scope. Tokens can only be decrypted by this Windows account.
internal sealed class TokenVault(string root)
{
    [StructLayout(LayoutKind.Sequential)] private struct Blob { public int Length; public IntPtr Data; }
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref Blob input, string? description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref Blob input, IntPtr description, IntPtr entropy, IntPtr reserved, IntPtr prompt, int flags, out Blob output);
    [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
    private string PathFor(Site site) => Path.Combine(root, "sessions", site.Key + ".bin");
    public Task Save(Site site, Tokens tokens)
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(tokens);
        try { return LocalStore.Atomic(PathFor(site), Protect(plain, true)); }
        finally { CryptographicOperations.ZeroMemory(plain); }
    }
    public async Task<Tokens?> Load(Site site)
    {
        try
        {
            var plain = Protect(await File.ReadAllBytesAsync(PathFor(site)), false);
            try { return JsonSerializer.Deserialize<Tokens>(plain); }
            finally { CryptographicOperations.ZeroMemory(plain); }
        }
        catch (Exception ex) when (ex is IOException or Win32Exception or JsonException or UnauthorizedAccessException) { return null; }
    }
    public void Remove(Site site) => File.Delete(PathFor(site));
    private static byte[] Protect(byte[] bytes, bool encrypt)
    {
        var pin = GCHandle.Alloc(bytes, GCHandleType.Pinned);
        var input = new Blob { Length = bytes.Length, Data = pin.AddrOfPinnedObject() };
        Blob output = default;
        try
        {
            var ok = encrypt ? CryptProtectData(ref input, "Laer session", IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output)
                : CryptUnprotectData(ref input, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, 1, out output);
            if (!ok) throw new Win32Exception(Marshal.GetLastWin32Error());
            var result = new byte[output.Length]; Marshal.Copy(output.Data, result, 0, result.Length); return result;
        }
        finally
        {
            if (output.Data != IntPtr.Zero)
            {
                // Also clear the unmanaged plaintext returned by CryptUnprotectData.
                if (!encrypt) Marshal.Copy(new byte[output.Length], 0, output.Data, output.Length);
                LocalFree(output.Data);
            }
            pin.Free();
        }
    }
}
