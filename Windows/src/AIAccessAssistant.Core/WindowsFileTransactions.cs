using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace AIAccessAssistant.Core;

public sealed class WindowsTransactionBusyException(string message)
    : IOException(message);

public class WindowsTransactionRecoveryRequiredException(
    string message,
    Exception? innerException = null)
    : IOException(message, innerException);

public sealed class WindowsReplaceFileAmbiguousException(
    int nativeErrorCode)
    : WindowsNativeOperationException("ReplaceFileW.ambiguous_state", nativeErrorCode);

public sealed class NamedWindowsTransactionMutex : IWindowsTransactionMutex
{
    private const string AllowedPrefix = "Local\\io.github.liewlf.aiaccessassistant.";

    public IDisposable Acquire(string name, TimeSpan timeout)
    {
        ValidateName(name);
        if (timeout < TimeSpan.Zero || timeout > TimeSpan.FromMinutes(2))
        {
            throw new ArgumentOutOfRangeException(
                nameof(timeout),
                "Mutex timeout must be between zero and two minutes.");
        }
        WindowsNativeGuard.RequireWindows("Named Mutex");

        var mutex = new Mutex(initiallyOwned: false, name);
        try
        {
            if (!mutex.WaitOne(timeout))
            {
                throw new WindowsTransactionBusyException(
                    "Another AI接入助手 configuration transaction is active.");
            }
            return new MutexLease(mutex, Environment.CurrentManagedThreadId);
        }
        catch (AbandonedMutexException error)
        {
            try
            {
                mutex.ReleaseMutex();
            }
            finally
            {
                mutex.Dispose();
            }
            throw new WindowsTransactionRecoveryRequiredException(
                "A previous configuration transaction ended unexpectedly; recovery verification is required.",
                error);
        }
        catch
        {
            mutex.Dispose();
            throw;
        }
    }

    public static void ValidateName(string name)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(name);
        if (!name.StartsWith(AllowedPrefix, StringComparison.Ordinal) ||
            name.Length > 128 ||
            name[AllowedPrefix.Length..].Length == 0 ||
            name[AllowedPrefix.Length..].Any(character =>
                !char.IsAsciiLetterOrDigit(character) &&
                character is not '.' and not '_' and not '-'))
        {
            throw new ArgumentException(
                "Mutex name is outside the application-owned namespace.",
                nameof(name));
        }
    }

    private sealed class MutexLease(
        Mutex mutex,
        int ownerManagedThreadId) : IDisposable
    {
        private bool _disposed;

        public void Dispose()
        {
            if (_disposed)
            {
                return;
            }
            if (Environment.CurrentManagedThreadId != ownerManagedThreadId)
            {
                throw new InvalidOperationException(
                    "Named mutex must be released by the acquiring thread.");
            }
            mutex.ReleaseMutex();
            mutex.Dispose();
            _disposed = true;
        }
    }
}

public sealed class WindowsAtomicFileReplacer : IWindowsAtomicFileReplacer
{
    private const uint OwnerSecurityInformation = 0x00000001;
    private const uint GroupSecurityInformation = 0x00000002;
    private const uint DaclSecurityInformation = 0x00000004;
    private const uint RequestedSecurityInformation =
        OwnerSecurityInformation |
        GroupSecurityInformation |
        DaclSecurityInformation;
    private const uint SddlRevision1 = 1;
    private const int ErrorInsufficientBuffer = 122;

    private static readonly HashSet<int> AmbiguousReplaceErrors =
        [1175, 1176, 1177];

    public WindowsFileSecuritySnapshot Snapshot(string path)
    {
        WindowsNativeGuard.RequireWindows("ReplaceFile/ACL snapshot");
        var normalized = WindowsLocalPathPolicy.ValidateExistingFile(path);
        var info = new FileInfo(normalized);
        info.Refresh();
        if (info.Length > WindowsNativeTransactionContract.MaximumConfigurationBytes)
        {
            throw new IOException(
                $"Configuration exceeds {WindowsNativeTransactionContract.MaximumConfigurationBytes} bytes.");
        }

        return new WindowsFileSecuritySnapshot(
            ReadSecurityDescriptorSddl(
                normalized,
                RequestedSecurityInformation),
            ReadSecurityDescriptorSddl(normalized, DaclSecurityInformation),
            info.Attributes,
            info.CreationTimeUtc,
            info.LastWriteTimeUtc,
            info.Length,
            HashFile(normalized));
    }

    public WindowsFileReplacementReceipt ReplaceFile(
        string destination,
        string replacement,
        string backup,
        string expectedSha256,
        WindowsFileSecuritySnapshot expectedMetadata)
    {
        ArgumentNullException.ThrowIfNull(expectedMetadata);
        WindowsNativeGuard.RequireWindows("ReplaceFileW");
        ValidateSha256(expectedSha256, nameof(expectedSha256));

        var normalizedDestination =
            WindowsLocalPathPolicy.ValidateExistingFile(destination);
        var normalizedReplacement =
            WindowsLocalPathPolicy.ValidateExistingFile(replacement);
        var normalizedBackup =
            WindowsLocalPathPolicy.ValidateNewFilePath(backup);
        WindowsLocalPathPolicy.RequireSameDirectory(
            normalizedDestination,
            normalizedReplacement,
            normalizedBackup);

        var replacementSnapshot = Snapshot(normalizedReplacement);
        var current = Snapshot(normalizedDestination);
        if (!string.Equals(
                current.Sha256,
                expectedSha256,
                StringComparison.OrdinalIgnoreCase) ||
            current != expectedMetadata)
        {
            throw new WindowsTransactionBusyException(
                "Configuration changed after preview; transaction was not applied.");
        }

        if (!ReplaceFileNative(
                normalizedDestination,
                normalizedReplacement,
                normalizedBackup,
                0,
                IntPtr.Zero,
                IntPtr.Zero))
        {
            var error = Marshal.GetLastWin32Error();
            if (AmbiguousReplaceErrors.Contains(error))
            {
                throw new WindowsReplaceFileAmbiguousException(error);
            }
            throw new WindowsNativeOperationException("ReplaceFileW", error);
        }

        try
        {
            RestoreDacl(normalizedDestination, expectedMetadata.DaclSddl);
        }
        catch (WindowsNativeOperationException error)
        {
            throw new WindowsTransactionRecoveryRequiredException(
                "Atomic replacement completed but original DACL restoration failed; backup was preserved.",
                error);
        }

        var destinationAfter = Snapshot(normalizedDestination);
        var backupAfter = Snapshot(normalizedBackup);
        var securityPreserved = string.Equals(
            destinationAfter.DaclSddl,
            expectedMetadata.DaclSddl,
            StringComparison.Ordinal);
        var attributesPreserved =
            destinationAfter.Attributes == expectedMetadata.Attributes;
        var creationTimePreserved =
            destinationAfter.CreationTimeUtc == expectedMetadata.CreationTimeUtc;
        var destinationIdentityMatches = string.Equals(
            destinationAfter.Sha256,
            replacementSnapshot.Sha256,
            StringComparison.OrdinalIgnoreCase);
        var backupIdentityMatches = string.Equals(
            backupAfter.Sha256,
            expectedMetadata.Sha256,
            StringComparison.OrdinalIgnoreCase);
        var daclAcesPreserved = string.Equals(
            DaclAces(destinationAfter.DaclSddl),
            DaclAces(expectedMetadata.DaclSddl),
            StringComparison.Ordinal);

        if (!destinationIdentityMatches ||
            !backupIdentityMatches ||
            !securityPreserved ||
            !attributesPreserved ||
            !creationTimePreserved)
        {
            throw new WindowsTransactionRecoveryRequiredException(
                "Atomic replacement completed but post-write verification failed; " +
                $"destination_identity={Result(destinationIdentityMatches)} " +
                $"backup_identity={Result(backupIdentityMatches)} " +
                $"security={Result(securityPreserved)} " +
                $"dacl_aces={Result(daclAcesPreserved)} " +
                $"expected_dacl_flags={DaclFlags(expectedMetadata.DaclSddl)} " +
                $"actual_dacl_flags={DaclFlags(destinationAfter.DaclSddl)} " +
                $"expected_ace_count={AceCount(expectedMetadata.DaclSddl)} " +
                $"actual_ace_count={AceCount(destinationAfter.DaclSddl)} " +
                $"attributes={Result(attributesPreserved)} " +
                $"creation_time={Result(creationTimePreserved)}; " +
                "backup was preserved.");
        }

        return new WindowsFileReplacementReceipt(
            destinationAfter.Sha256,
            backupAfter.Sha256,
            securityPreserved,
            attributesPreserved,
            creationTimePreserved);
    }

    private static string Result(bool passed) => passed ? "PASS" : "FAIL";

    private static string DaclFlags(string sddl)
    {
        var firstAce = sddl.IndexOf('(');
        return firstAce < 0 ? sddl : sddl[..firstAce];
    }

    private static string DaclAces(string sddl)
    {
        var firstAce = sddl.IndexOf('(');
        return firstAce < 0 ? string.Empty : sddl[firstAce..];
    }

    private static int AceCount(string sddl) =>
        sddl.Count(character => character == '(');

    private static void RestoreDacl(string path, string daclSddl)
    {
        if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                daclSddl,
                SddlRevision1,
                out var descriptor,
                out _))
        {
            throw new WindowsNativeOperationException(
                "ConvertStringSecurityDescriptorToSecurityDescriptorW",
                Marshal.GetLastWin32Error());
        }
        try
        {
            if (!SetFileSecurity(
                    path,
                    DaclSecurityInformation,
                    descriptor))
            {
                throw new WindowsNativeOperationException(
                    "SetFileSecurityW.DACL",
                    Marshal.GetLastWin32Error());
            }
        }
        finally
        {
            _ = LocalFree(descriptor);
        }
    }

    internal static string HashFile(string path)
    {
        using var stream = new FileStream(
            path,
            FileMode.Open,
            FileAccess.Read,
            FileShare.Read,
            bufferSize: 16 * 1024,
            options: FileOptions.SequentialScan);
        return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant();
    }

    internal static void ValidateSha256(string value, string parameterName)
    {
        if (value.Length != 64 ||
            value.Any(character => !Uri.IsHexDigit(character)))
        {
            throw new ArgumentException(
                "Expected SHA-256 must contain exactly 64 hexadecimal characters.",
                parameterName);
        }
    }

    private static string ReadSecurityDescriptorSddl(
        string path,
        uint requestedSecurityInformation)
    {
        _ = GetFileSecurity(
            path,
            requestedSecurityInformation,
            IntPtr.Zero,
            0,
            out var needed);
        var firstError = Marshal.GetLastWin32Error();
        if (needed == 0 || firstError != ErrorInsufficientBuffer)
        {
            throw new WindowsNativeOperationException(
                "GetFileSecurityW.size",
                firstError);
        }

        var descriptor = Marshal.AllocHGlobal(checked((int)needed));
        try
        {
            if (!GetFileSecurity(
                    path,
                    requestedSecurityInformation,
                    descriptor,
                    needed,
                    out _))
            {
                throw new WindowsNativeOperationException(
                    "GetFileSecurityW",
                    Marshal.GetLastWin32Error());
            }
            if (!ConvertSecurityDescriptorToString(
                    descriptor,
                    SddlRevision1,
                    requestedSecurityInformation,
                    out var sddlPointer,
                    out _))
            {
                throw new WindowsNativeOperationException(
                    "ConvertSecurityDescriptorToStringSecurityDescriptorW",
                    Marshal.GetLastWin32Error());
            }
            try
            {
                return Marshal.PtrToStringUni(sddlPointer) ??
                    throw new WindowsNativeOperationException(
                        "ConvertSecurityDescriptorToStringSecurityDescriptorW.empty",
                        87);
            }
            finally
            {
                _ = LocalFree(sddlPointer);
            }
        }
        finally
        {
            Marshal.FreeHGlobal(descriptor);
        }
    }

    [DllImport(
        "Kernel32.dll",
        EntryPoint = "ReplaceFileW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReplaceFileNative(
        string replacedFileName,
        string replacementFileName,
        string backupFileName,
        uint replaceFlags,
        IntPtr exclude,
        IntPtr reserved);

    [DllImport(
        "Advapi32.dll",
        EntryPoint = "GetFileSecurityW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileSecurity(
        string fileName,
        uint requestedInformation,
        IntPtr securityDescriptor,
        uint length,
        out uint lengthNeeded);

    [DllImport(
        "Advapi32.dll",
        EntryPoint = "ConvertSecurityDescriptorToStringSecurityDescriptorW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertSecurityDescriptorToString(
        IntPtr securityDescriptor,
        uint requestedStringSdRevision,
        uint securityInformation,
        out IntPtr stringSecurityDescriptor,
        out uint stringSecurityDescriptorLength);

    [DllImport(
        "Advapi32.dll",
        EntryPoint = "ConvertStringSecurityDescriptorToSecurityDescriptorW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
        string stringSecurityDescriptor,
        uint stringSdRevision,
        out IntPtr securityDescriptor,
        out uint securityDescriptorSize);

    [DllImport(
        "Advapi32.dll",
        EntryPoint = "SetFileSecurityW",
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileSecurity(
        string fileName,
        uint securityInformation,
        IntPtr securityDescriptor);

    [DllImport("Kernel32.dll", EntryPoint = "LocalFree", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);
}

internal static class WindowsLocalPathPolicy
{
    private const FileAttributes UnsafeAttributes =
        FileAttributes.Directory |
        FileAttributes.Device |
        FileAttributes.Offline |
        FileAttributes.ReparsePoint;

    public static string ValidateExistingFile(string path)
    {
        var normalized = ValidateLocalPath(path);
        if (!File.Exists(normalized) || Directory.Exists(normalized))
        {
            throw new FileNotFoundException(
                "Expected an existing ordinary local file.");
        }
        if ((File.GetAttributes(normalized) & UnsafeAttributes) != 0)
        {
            throw new IOException(
                "File uses unsupported directory, device, offline, or reparse attributes.");
        }
        return normalized;
    }

    public static string ValidateNewFilePath(string path)
    {
        var normalized = ValidateLocalPath(path);
        if (File.Exists(normalized) || Directory.Exists(normalized))
        {
            throw new IOException("New transaction path already exists.");
        }
        var parent = Path.GetDirectoryName(normalized) ??
            throw new IOException("Transaction path has no parent directory.");
        ValidateExistingDirectory(parent);
        return normalized;
    }

    public static string ValidateExistingDirectory(string path)
    {
        var normalized = ValidateLocalPath(path);
        if (!Directory.Exists(normalized))
        {
            throw new DirectoryNotFoundException(
                "Expected an existing local directory.");
        }
        var attributes = File.GetAttributes(normalized);
        if ((attributes & FileAttributes.ReparsePoint) != 0 ||
            (attributes & FileAttributes.Directory) == 0)
        {
            throw new IOException(
                "Directory is not an ordinary local directory.");
        }
        return normalized;
    }

    public static void RequireSameDirectory(params string[] paths)
    {
        if (paths.Length < 2)
        {
            throw new ArgumentException(
                "At least two paths are required.",
                nameof(paths));
        }
        var firstDirectory = Path.GetDirectoryName(paths[0]);
        if (firstDirectory is null || paths.Skip(1).Any(path =>
                !string.Equals(
                    Path.GetDirectoryName(path),
                    firstDirectory,
                    StringComparison.OrdinalIgnoreCase)))
        {
            throw new IOException(
                "Atomic replacement files must share one directory and volume.");
        }
    }

    private static string ValidateLocalPath(string path)
    {
        WindowsNativeGuard.RequireWindows("Windows local path validation");
        var normalized =
            WindowsInclusivePathPolicy.NormalizeOrdinaryLocalPath(path);
        var root = Path.GetPathRoot(normalized) ??
            throw new IOException("Local path root is unavailable.");
        var drive = new DriveInfo(root);
        if (drive.DriveType != DriveType.Fixed)
        {
            throw new IOException("Only fixed local volumes are supported.");
        }

        var current = Path.GetDirectoryName(normalized);
        while (!string.IsNullOrEmpty(current))
        {
            if (Directory.Exists(current) &&
                (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
            {
                throw new IOException(
                    "A parent directory is a reparse point; operation blocked.");
            }
            var parent = Path.GetDirectoryName(current);
            if (string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            current = parent;
        }
        return normalized;
    }
}
