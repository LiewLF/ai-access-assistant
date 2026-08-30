using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace AIAccessAssistant.Core;

public static class WindowsNativeTransactionContract
{
    public const int SourceBuild = 144;
    public const int MaximumCredentialBytes = 5 * 512;
    public const int MaximumCredentialTargetSuffixCharacters = 128;
    public const int MaximumConfigurationBytes = 2 * 1024 * 1024;
    public const string CredentialTargetPrefix = "io.github.liewlf.aiaccessassistant/relay/";
    public const string ConfigurationMutexName = "Local\\io.github.liewlf.aiaccessassistant.config.v1";
    public const string RuntimeState = "unverified";
}

public class WindowsNativeOperationException(
    string operation,
    int nativeErrorCode,
    Exception? innerException = null)
    : IOException(
        $"Windows native operation '{operation}' failed with code {nativeErrorCode}.",
        innerException)
{
    public string Operation { get; } = operation;
    public int NativeErrorCode { get; } = nativeErrorCode;
}

public sealed class WindowsCredentialManager : IWindowsCredentialManager
{
    private const uint CredentialTypeGeneric = 1;
    private const uint CredentialPersistLocalMachine = 2;
    private const int ErrorNotFound = 1168;

    public byte[]? ReadGenericCredential(string targetName)
    {
        ValidateTargetName(targetName);
        WindowsNativeGuard.RequireWindows("Credential Manager read");

        if (!CredRead(targetName, CredentialTypeGeneric, 0, out var pointer))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == ErrorNotFound)
            {
                return null;
            }
            throw new WindowsNativeOperationException("CredReadW", error);
        }
        if (pointer == IntPtr.Zero)
        {
            throw new WindowsNativeOperationException(
                "CredReadW.missing_result",
                87);
        }

        NativeCredential credential = default;
        var parsed = false;
        try
        {
            credential = Marshal.PtrToStructure<NativeCredential>(pointer);
            parsed = true;
            if (credential.CredentialBlobSize >
                WindowsNativeTransactionContract.MaximumCredentialBytes)
            {
                throw new WindowsNativeOperationException(
                    "CredReadW.invalid_blob_size",
                    87);
            }
            if (credential.CredentialBlobSize == 0)
            {
                return [];
            }
            if (credential.CredentialBlob == IntPtr.Zero)
            {
                throw new WindowsNativeOperationException(
                    "CredReadW.missing_blob",
                    87);
            }

            var blobSize = checked((int)credential.CredentialBlobSize);
            var secret = new byte[blobSize];
            Marshal.Copy(
                credential.CredentialBlob,
                secret,
                0,
                secret.Length);
            return secret;
        }
        finally
        {
            if (parsed &&
                credential.CredentialBlob != IntPtr.Zero &&
                credential.CredentialBlobSize > 0 &&
                credential.CredentialBlobSize <=
                    WindowsNativeTransactionContract.MaximumCredentialBytes)
            {
                var zeros = new byte[checked((int)credential.CredentialBlobSize)];
                Marshal.Copy(
                    zeros,
                    0,
                    credential.CredentialBlob,
                    zeros.Length);
            }
            if (pointer != IntPtr.Zero)
            {
                CredFree(pointer);
            }
        }
    }

    public void WriteGenericCredential(
        string targetName,
        ReadOnlySpan<byte> secret)
    {
        ValidateTargetName(targetName);
        if (secret.IsEmpty ||
            secret.Length > WindowsNativeTransactionContract.MaximumCredentialBytes)
        {
            throw new ArgumentOutOfRangeException(
                nameof(secret),
                $"Credential must contain 1-{WindowsNativeTransactionContract.MaximumCredentialBytes} bytes.");
        }
        WindowsNativeGuard.RequireWindows("Credential Manager write");

        var managedCopy = secret.ToArray();
        var unmanagedCopy = Marshal.AllocHGlobal(managedCopy.Length);
        try
        {
            Marshal.Copy(managedCopy, 0, unmanagedCopy, managedCopy.Length);
            var credential = new NativeCredential
            {
                Type = CredentialTypeGeneric,
                TargetName = targetName,
                CredentialBlobSize = (uint)managedCopy.Length,
                CredentialBlob = unmanagedCopy,
                Persist = CredentialPersistLocalMachine,
            };
            if (!CredWrite(ref credential, 0))
            {
                throw new WindowsNativeOperationException(
                    "CredWriteW",
                    Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            var zeros = new byte[managedCopy.Length];
            Marshal.Copy(zeros, 0, unmanagedCopy, zeros.Length);
            Marshal.FreeHGlobal(unmanagedCopy);
            CryptographicOperations.ZeroMemory(managedCopy);
        }
    }

    public void DeleteGenericCredential(string targetName)
    {
        ValidateTargetName(targetName);
        WindowsNativeGuard.RequireWindows("Credential Manager delete");

        if (CredDelete(targetName, CredentialTypeGeneric, 0))
        {
            return;
        }
        var error = Marshal.GetLastWin32Error();
        if (error != ErrorNotFound)
        {
            throw new WindowsNativeOperationException("CredDeleteW", error);
        }
    }

    public static void ValidateTargetName(string targetName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(targetName);
        if (!targetName.StartsWith(
                WindowsNativeTransactionContract.CredentialTargetPrefix,
                StringComparison.Ordinal))
        {
            throw new ArgumentException(
                "Credential target is outside the application-owned namespace.",
                nameof(targetName));
        }

        var suffix = targetName[
            WindowsNativeTransactionContract.CredentialTargetPrefix.Length..];
        if (suffix.Length is < 1 or >
            WindowsNativeTransactionContract.MaximumCredentialTargetSuffixCharacters ||
            suffix.Any(character =>
                !char.IsAsciiLetterOrDigit(character) &&
                character is not '.' and not '_' and not '-'))
        {
            throw new ArgumentException(
                "Credential target suffix is invalid.",
                nameof(targetName));
        }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NativeCredential
    {
        public uint Flags;
        public uint Type;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? TargetName;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? Comment;

        public System.Runtime.InteropServices.ComTypes.FILETIME LastWritten;
        public uint CredentialBlobSize;
        public IntPtr CredentialBlob;
        public uint Persist;
        public uint AttributeCount;
        public IntPtr Attributes;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? TargetAlias;

        [MarshalAs(UnmanagedType.LPWStr)]
        public string? UserName;
    }

    [DllImport(
        "Advapi32.dll",
        EntryPoint = "CredReadW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredRead(
        string targetName,
        uint type,
        uint flags,
        out IntPtr credential);

    [DllImport(
        "Advapi32.dll",
        EntryPoint = "CredWriteW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredWrite(
        ref NativeCredential credential,
        uint flags);

    [DllImport(
        "Advapi32.dll",
        EntryPoint = "CredDeleteW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CredDelete(
        string targetName,
        uint type,
        uint flags);

    [DllImport("Advapi32.dll", EntryPoint = "CredFree")]
    private static extern void CredFree(IntPtr buffer);
}

internal static class WindowsNativeGuard
{
    public static void RequireWindows(string operation)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException(
                $"{operation} is available only on Windows.");
        }
    }
}
