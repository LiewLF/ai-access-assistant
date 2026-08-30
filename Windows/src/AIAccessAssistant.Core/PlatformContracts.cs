namespace AIAccessAssistant.Core;

public static class WindowsProductContract
{
    public const int SourceBuild = 142;
    public const int MinimumWindowsBuild = 22000;
    public const string RuntimeIdentifier = "win-x64";
    public const string RuntimeState = "unverified";
}

public sealed record WindowsFileSecuritySnapshot(
    string SecurityDescriptorSddl,
    string DaclSddl,
    FileAttributes Attributes,
    DateTime CreationTimeUtc,
    DateTime LastWriteTimeUtc,
    long Length,
    string Sha256);

public sealed record WindowsFileReplacementReceipt(
    string DestinationSha256,
    string BackupSha256,
    bool SecurityDescriptorPreserved,
    bool AttributesPreserved,
    bool CreationTimePreserved);

public interface IWindowsCredentialManager
{
    byte[]? ReadGenericCredential(string targetName);
    void WriteGenericCredential(string targetName, ReadOnlySpan<byte> secret);
    void DeleteGenericCredential(string targetName);
}

public interface IWindowsAtomicFileReplacer
{
    WindowsFileSecuritySnapshot Snapshot(string path);
    WindowsFileReplacementReceipt ReplaceFile(
        string destination,
        string replacement,
        string backup,
        string expectedSha256,
        WindowsFileSecuritySnapshot expectedMetadata);
}

public interface IWindowsTransactionMutex
{
    IDisposable Acquire(string name, TimeSpan timeout);
}

public interface IWindowsProcessController
{
    IReadOnlyList<int> FindConfigurationWriters();
    void RequestGracefulExit(int processId);
    int LaunchCodex(IReadOnlyDictionary<string, string> environment);
    bool WaitForExit(int processId, TimeSpan timeout);
}

public sealed class PlatformCapabilityUnavailableException(string capability)
    : InvalidOperationException(
        $"Windows capability '{capability}' is not implemented in read-only MVP; operation blocked.");

public sealed class DeferredCredentialManager : IWindowsCredentialManager
{
    public byte[]? ReadGenericCredential(string targetName) =>
        throw new PlatformCapabilityUnavailableException("Credential Manager read");

    public void WriteGenericCredential(string targetName, ReadOnlySpan<byte> secret) =>
        throw new PlatformCapabilityUnavailableException("Credential Manager write");

    public void DeleteGenericCredential(string targetName) =>
        throw new PlatformCapabilityUnavailableException("Credential Manager delete");
}

public sealed class DeferredAtomicFileReplacer : IWindowsAtomicFileReplacer
{
    public WindowsFileSecuritySnapshot Snapshot(string path) =>
        throw new PlatformCapabilityUnavailableException("ReplaceFile/ACL snapshot");

    public WindowsFileReplacementReceipt ReplaceFile(
        string destination,
        string replacement,
        string backup,
        string expectedSha256,
        WindowsFileSecuritySnapshot expectedMetadata) =>
        throw new PlatformCapabilityUnavailableException("ReplaceFile/ACL replacement");
}

public sealed class DeferredTransactionMutex : IWindowsTransactionMutex
{
    public IDisposable Acquire(string name, TimeSpan timeout) =>
        throw new PlatformCapabilityUnavailableException("Named Mutex");
}

public sealed class DeferredProcessController : IWindowsProcessController
{
    public IReadOnlyList<int> FindConfigurationWriters() =>
        throw new PlatformCapabilityUnavailableException("process discovery");

    public void RequestGracefulExit(int processId) =>
        throw new PlatformCapabilityUnavailableException("process graceful exit");

    public int LaunchCodex(IReadOnlyDictionary<string, string> environment) =>
        throw new PlatformCapabilityUnavailableException("process launch");

    public bool WaitForExit(int processId, TimeSpan timeout) =>
        throw new PlatformCapabilityUnavailableException("process wait");
}
