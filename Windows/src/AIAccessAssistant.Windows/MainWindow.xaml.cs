using AIAccessAssistant.Core;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using System.Security;
using System.Security.Cryptography;
using System.Text;
using Windows.Storage.Pickers;

namespace AIAccessAssistant.Windows;

public sealed partial class MainWindow : Window
{
    private readonly ReadOnlyWindowsCodexReadinessService _readinessService =
        new();
    private readonly WindowsProgressiveVerificationService _verificationService =
        new();
    private readonly WindowsHistoryContinuityScanner _historyScanner = new();
    private readonly SemaphoreSlim _verificationInteraction = new(1, 1);
    private readonly SemaphoreSlim _continuityInteraction = new(1, 1);
    private WindowsContinuityImportCoordinator? _continuityCoordinator;
    private WindowsCodexReadinessSnapshot? _readinessSnapshot;

    private WindowsContinuityImportCoordinator ContinuityCoordinator =>
        _continuityCoordinator ??= new WindowsContinuityImportCoordinator();

    public MainWindow()
    {
        InitializeComponent();
        Activated += MainWindow_Activated;
    }

    private async void MainWindow_Activated(object sender, WindowActivatedEventArgs args)
    {
        Activated -= MainWindow_Activated;
        await RefreshPreviewAsync();
        RefreshRecoveryIndicator();
    }

    private async void RefreshPreview_Click(object sender, RoutedEventArgs e)
    {
        await RefreshPreviewAsync();
    }

    private async void BasicVerification_Click(object sender, RoutedEventArgs e)
    {
        await RunVerificationAsync(WindowsVerificationStep.BasicConnection);
    }

    private async void RealTaskVerification_Click(object sender, RoutedEventArgs e)
    {
        await RunVerificationAsync(WindowsVerificationStep.RealTask);
    }

    private async void ImportContinuity_Click(object sender, RoutedEventArgs e)
    {
        await RunContinuityInteractionAsync(
            ImportContinuityCoreAsync,
            WindowsInclusiveOperation.ContinuityImport,
            ImportContinuityButton);
    }

    private async void RecoverContinuity_Click(object sender, RoutedEventArgs e)
    {
        await RunContinuityInteractionAsync(
            RecoverContinuityCoreAsync,
            WindowsInclusiveOperation.ContinuityRecovery,
            RecoverContinuityButton);
    }

    private async void RefreshHistory_Click(object sender, RoutedEventArgs e)
    {
        await RunContinuityInteractionAsync(
            RefreshHistoryCoreAsync,
            WindowsInclusiveOperation.HistoryRefresh,
            RefreshHistoryButton);
    }

    private async Task RefreshPreviewAsync()
    {
        LoadingIndicator.IsActive = true;
        StatusBar.Severity = InfoBarSeverity.Informational;
        StatusBar.Title = "识别中";
        StatusBar.Message = "正在有限路径内只读识别；不会启动 Codex 或写入文件。";

        try
        {
            var snapshot = await _readinessService.InspectAsync();
            _readinessSnapshot = snapshot;
            CanWorkText.Text = snapshot.Outcome.Conclusion;
            InstallationText.Text = snapshot.Installation.Summary;
            AccessText.Text = snapshot.Access.Summary;
            PrimaryActionText.Text = snapshot.Outcome.PrimaryAction;
            ContinuationText.Text = snapshot.Outcome.Continuation;
            PathText.Text = string.IsNullOrWhiteSpace(
                snapshot.ConfigurationPreview.Path)
                ? "尚未确认配置路径"
                : snapshot.ConfigurationPreview.Path;
            PreviewText.Text = snapshot.ConfigurationPreview.Content;
            StatusBar.Title = snapshot.Outcome.State switch
            {
                WindowsCanWorkState.NotReady => "尚未就绪",
                WindowsCanWorkState.NeedsAttention => "需要处理一项问题",
                _ => "只读识别完成",
            };
            StatusBar.Severity = snapshot.Outcome.State switch
            {
                WindowsCanWorkState.NotReady => InfoBarSeverity.Warning,
                WindowsCanWorkState.NeedsAttention => InfoBarSeverity.Warning,
                _ => InfoBarSeverity.Informational,
            };
            StatusBar.Message = snapshot.TechnicalStatus;
            var canPrepareVerification =
                snapshot.Installation.State == WindowsCodexInstallationState.Found &&
                snapshot.Access.Kind != WindowsCodexAccessKind.Blocked;
            BasicVerificationButton.IsEnabled = canPrepareVerification;
            RealTaskVerificationButton.IsEnabled = false;
            VerificationStageText.Text = canPrepareVerification
                ? "第1步：检测基础连接；点击后会先显示费用确认。"
                : "先完成只读识别，再开始验证。";
            VerificationEvidenceText.Text = "尚无失败证据";
        }
        catch (Exception error) when (
            error is ConfigurationDiscoveryException or
            ConfigurationPreviewException or
            DecoderFallbackException or
            IOException or
            ArgumentException or
            NotSupportedException or
            UnauthorizedAccessException or
            SecurityException)
        {
            PreviewText.Text = string.Empty;
            InvalidateReadinessAfterFailure();
            PresentInclusiveFailure(
                error,
                WindowsInclusiveOperation.ReadinessRefresh);
        }
        finally
        {
            LoadingIndicator.IsActive = false;
        }
    }

    private async Task RunVerificationAsync(WindowsVerificationStep step)
    {
        if (!await _verificationInteraction.WaitAsync(0))
        {
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "已有确认或验证在进行";
            StatusBar.Message = "没有打开第二个确认框，也没有启动第二次请求。";
            return;
        }
        try
        {
            await RunVerificationCoreAsync(step);
        }
        catch (Exception error)
        {
            RestoreVerificationButton(step);
            VerificationIndicator.IsActive = false;
            PresentInclusiveFailure(error, InclusiveOperationFor(step));
        }
        finally
        {
            var preferred = step == WindowsVerificationStep.BasicConnection &&
                    RealTaskVerificationButton.IsEnabled
                ? RealTaskVerificationButton
                : step == WindowsVerificationStep.BasicConnection
                    ? BasicVerificationButton
                    : RealTaskVerificationButton;
            RestoreKeyboardFocus(preferred, RefreshPreviewButton);
            _verificationInteraction.Release();
        }
    }

    private async Task RunVerificationCoreAsync(WindowsVerificationStep step)
    {
        var snapshot = _readinessSnapshot;
        if (snapshot is null)
        {
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "先读取当前状态";
            StatusBar.Message = "尚未形成可绑定的 Codex 和配置证据。";
            return;
        }

        WindowsVerificationConsentPlan plan;
        try
        {
            plan = _verificationService.Prepare(snapshot, step);
        }
        catch (Exception error) when (
            error is IOException or
            UnauthorizedAccessException or
            DecoderFallbackException or
            InvalidOperationException or
            ArgumentException or
            SecurityException)
        {
            PresentInclusiveFailure(error, InclusiveOperationFor(step));
            return;
        }

        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = plan.ConfirmationTitle,
            Content = plan.ConfirmationMessage,
            PrimaryButtonText = step == WindowsVerificationStep.BasicConnection
                ? "确认并检测"
                : "确认并验证",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        BasicVerificationButton.IsEnabled = false;
        RealTaskVerificationButton.IsEnabled = false;
        var confirmation = await dialog.ShowAsync();
        if (confirmation != ContentDialogResult.Primary)
        {
            RestoreVerificationButton(step);
            StatusBar.Severity = InfoBarSeverity.Informational;
            StatusBar.Title = "已取消";
            StatusBar.Message = "未启动 Codex、未联网、未读取中转凭据，也未产生验证请求。";
            return;
        }

        VerificationIndicator.IsActive = true;
        BasicVerificationButton.IsEnabled = false;
        RealTaskVerificationButton.IsEnabled = false;
        VerificationStageText.Text =
            step == WindowsVerificationStep.BasicConnection
                ? "第1步：正在检测基础连接"
                : "第2步：正在隔离环境验证真实工具任务";
        StatusBar.Severity = InfoBarSeverity.Informational;
        StatusBar.Title = "验证中";
        StatusBar.Message = "本次最多一个模型请求；不会自动重试或切换接入。";

        try
        {
            var outcome = await _verificationService.ExecuteAsync(
                plan,
                userConfirmed: true);
            VerificationStageText.Text = outcome.Conclusion;
            PrimaryActionText.Text = outcome.PrimaryAction;
            CanWorkText.Text = outcome.Stage == WindowsVerificationStage.Ready
                ? outcome.Conclusion
                : snapshot.Outcome.Conclusion;
            if (outcome.Failure is not null)
            {
                VerificationEvidenceText.Text = string.Join(
                    Environment.NewLine,
                    outcome.Failure.Evidence);
                StatusBar.Severity = InfoBarSeverity.Warning;
                StatusBar.Title = "验证未通过";
                StatusBar.Message = outcome.Failure.Explanation;
                BasicVerificationButton.IsEnabled =
                    step == WindowsVerificationStep.BasicConnection;
                RealTaskVerificationButton.IsEnabled =
                    step == WindowsVerificationStep.RealTask;
            }
            else if (outcome.Stage == WindowsVerificationStage.NeedsRealTask)
            {
                VerificationEvidenceText.Text = "第1步已通过；第2步尚未执行。";
                RealTaskVerificationButton.IsEnabled = true;
                StatusBar.Severity = InfoBarSeverity.Informational;
                StatusBar.Title = "基础连接已通过";
                StatusBar.Message = "仍需单独确认真实任务验证，才可证明能够完成工作。";
            }
            else
            {
                VerificationEvidenceText.Text = "两步结构证据均已通过。";
                StatusBar.Severity = InfoBarSeverity.Success;
                StatusBar.Title = "真实任务可用";
                StatusBar.Message = "模型调用、工具执行、结果续接和最终回复已形成完整闭环。";
            }
        }
        catch (WindowsVerificationBusyException)
        {
            RestoreVerificationButton(step);
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "已有验证在运行";
            StatusBar.Message = "没有启动第二次请求。";
        }
        catch (Exception error) when (
            error is WindowsVerificationPlanExpiredException or
            WindowsVerificationConsentRequiredException)
        {
            RestoreVerificationButton(step);
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "本次确认已失效";
            StatusBar.Message = "没有启动请求；请重新点击并确认。";
        }
        catch (OperationCanceledException)
        {
            RestoreVerificationButton(step);
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "验证已停止";
            StatusBar.Message = "本次结果未采用；先确认本次 Codex 进程已结束，再手动重试。";
        }
        catch (Exception error) when (
            error is IOException or
            UnauthorizedAccessException or
            DecoderFallbackException or
            CryptographicException or
            InvalidOperationException or
            ArgumentException or
            SecurityException)
        {
            RestoreVerificationButton(step);
            PresentInclusiveFailure(error, InclusiveOperationFor(step));
        }
        finally
        {
            VerificationIndicator.IsActive = false;
        }
    }

    private sealed record ContinuityFieldSelection(
        bool Relays,
        bool Workspaces,
        bool StartDestination,
        bool HistoryGrouping);

    private sealed record ContinuityDecisions(
        IReadOnlyList<WindowsContinuityRelayDecision> Relays,
        IReadOnlyList<WindowsContinuityWorkspaceDecision> Workspaces);

    private async Task RunContinuityInteractionAsync(
        Func<Task> operation,
        WindowsInclusiveOperation inclusiveOperation,
        Control focusTarget)
    {
        if (!await _continuityInteraction.WaitAsync(0))
        {
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "迁移或历史操作正在进行";
            StatusBar.Message = "没有打开第二个选择框，也没有启动第二次写入。";
            return;
        }
        ContinuityIndicator.IsActive = true;
        ImportContinuityButton.IsEnabled = false;
        RefreshHistoryButton.IsEnabled = false;
        RecoverContinuityButton.IsEnabled = false;
        try
        {
            await operation();
        }
        catch (WindowsContinuityPendingRecoveryException)
        {
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "先恢复上次迁移";
            StatusBar.Message = "新的导入已阻止；只有“恢复上次迁移”一个处理动作。";
            RefreshRecoveryIndicator();
        }
        catch (WindowsContinuityPlanExpiredException)
        {
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "迁移预览已失效";
            StatusBar.Message = "未采用任何设置；重新选择文件并预览。";
        }
        catch (Exception error) when (
            error is WindowsContinuityManifestException or
            WindowsContinuityRecoveryRequiredException or
            WindowsHistoryContinuityException or
            WindowsTransactionBusyException or
            WindowsTransactionRecoveryRequiredException or
            ConfigurationDiscoveryException or
            IOException or
            UnauthorizedAccessException or
            ArgumentException or
            InvalidOperationException or
            CryptographicException or
            SecurityException)
        {
            PresentInclusiveFailure(error, inclusiveOperation);
            RefreshRecoveryIndicator();
        }
        finally
        {
            ContinuityIndicator.IsActive = false;
            RefreshHistoryButton.IsEnabled = true;
            if (RecoverContinuityButton.Visibility == Visibility.Visible)
            {
                RecoverContinuityButton.IsEnabled = true;
            }
            else
            {
                ImportContinuityButton.IsEnabled = true;
            }
            RestoreKeyboardFocus(focusTarget, ImportContinuityButton);
            _continuityInteraction.Release();
        }
    }

    private async Task ImportContinuityCoreAsync()
    {
        var picker = new FileOpenPicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            ViewMode = PickerViewMode.List,
        };
        picker.FileTypeFilter.Add(".json");
        var windowHandle = WinRT.Interop.WindowNative.GetWindowHandle(this);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, windowHandle);
        var file = await picker.PickSingleFileAsync();
        if (file is null)
        {
            StatusBar.Severity = InfoBarSeverity.Informational;
            StatusBar.Title = "已取消选择";
            StatusBar.Message = "未读取迁移文件，未写入设置或凭据。";
            return;
        }

        StatusBar.Severity = InfoBarSeverity.Informational;
        StatusBar.Title = "正在预览迁移设置";
        StatusBar.Message = "只读取所选普通 JSON；尚未写入设置或凭据。";
        var session = await Task.Run(() =>
            ContinuityCoordinator.Prepare(file.Path));
        ContinuityEvidenceText.Text = DescribePreview(session.Preview);
        if (!session.Preview.CanApply)
        {
            ContinuitySummaryText.Text =
                "迁移预览存在冲突或没有可应用变化；未写入任何内容。";
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "迁移不能继续";
            StatusBar.Message = "先处理预览中的冲突，再重新选择文件。";
            return;
        }

        var selection = await ShowFieldSelectionAsync(session);
        if (selection is null)
        {
            StatusBar.Severity = InfoBarSeverity.Informational;
            StatusBar.Title = "已取消迁移";
            StatusBar.Message = "预览后已停止；未写入设置或凭据。";
            return;
        }
        if (!selection.Relays &&
            !selection.Workspaces &&
            !selection.StartDestination &&
            !selection.HistoryGrouping)
        {
            StatusBar.Severity = InfoBarSeverity.Warning;
            StatusBar.Title = "尚未选择迁移内容";
            StatusBar.Message = "至少选择一类有变化的非敏感设置。";
            return;
        }

        var target = ContinuityCoordinator.LoadTargetState();
        var decisions = await CollectContinuityDecisionsAsync(
            session,
            target,
            selection);
        if (decisions is null)
        {
            StatusBar.Severity = InfoBarSeverity.Informational;
            StatusBar.Title = "已取消迁移";
            StatusBar.Message = "未完成逐项选择；未写入设置或凭据。";
            return;
        }

        try
        {
            if (!await ConfirmContinuityApplyAsync(decisions, selection))
            {
                StatusBar.Severity = InfoBarSeverity.Informational;
                StatusBar.Title = "已取消最终确认";
                StatusBar.Message = "未写入设置或凭据，当前接入保持不变。";
                return;
            }
            var request = new WindowsContinuityApplyRequest(
                session,
                decisions.Relays,
                decisions.Workspaces,
                selection.StartDestination,
                selection.HistoryGrouping,
                UserConfirmed: true);
            var result = await Task.Run(() =>
                ContinuityCoordinator.Apply(request));
            ContinuitySummaryText.Text =
                $"已新增 {result.ImportedRelayCount} 个中转设置，映射 " +
                $"{result.MappedWorkspaceCount} 个工作区标签。{result.Continuation}";
            StatusBar.Severity = InfoBarSeverity.Success;
            StatusBar.Title = "迁移设置已保存";
            StatusBar.Message =
                "当前接入和 Codex 配置未切换；新中转仍是未验证状态。";
            RefreshRecoveryIndicator();
        }
        finally
        {
            ZeroRelayDecisions(decisions.Relays);
        }
    }

    private async Task RecoverContinuityCoreAsync()
    {
        var phase = ContinuityCoordinator.PendingRecoveryPhase();
        if (phase is null)
        {
            RefreshRecoveryIndicator();
            StatusBar.Severity = InfoBarSeverity.Informational;
            StatusBar.Title = "没有待恢复迁移";
            StatusBar.Message = "未执行写入。";
            return;
        }
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "恢复上次迁移？",
            Content =
                "助手将核对固定应用目录中的事务证据：已提交事务只完成清理；未提交事务恢复原状态并删除本次新增凭据。不会自动重试迁移。",
            PrimaryButtonText = "确认恢复",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            StatusBar.Severity = InfoBarSeverity.Informational;
            StatusBar.Title = "已取消恢复";
            StatusBar.Message = "恢复证据保持不变；新的迁移继续阻止。";
            return;
        }
        var recovered = await Task.Run(() =>
            ContinuityCoordinator.RecoverPending(userConfirmed: true));
        ContinuitySummaryText.Text = recovered == 0
            ? "没有发现待恢复迁移。"
            : "上次迁移已按事务证据恢复；可以重新预览迁移文件。";
        StatusBar.Severity = InfoBarSeverity.Success;
        StatusBar.Title = "迁移恢复完成";
        StatusBar.Message = "未自动重新导入、切换接入或运行验证。";
        RefreshRecoveryIndicator();
    }

    private async Task RefreshHistoryCoreAsync()
    {
        StatusBar.Severity = InfoBarSeverity.Informational;
        StatusBar.Title = "正在刷新历史元数据";
        StatusBar.Message = "只检查固定 sessions 日期目录中的文件时间和大小。";
        var paths = CodexConfigurationPaths.Discover();
        var snapshot = await Task.Run(() => _historyScanner.Scan(paths));
        HistoryList.Items.Clear();
        foreach (var entry in snapshot.Entries)
        {
            var state = entry.State == WindowsHistoryEntryState.Available
                ? "可继续"
                : "空文件，需注意";
            HistoryList.Items.Add(
                $"{entry.LastWriteUtc.ToLocalTime():yyyy-MM-dd HH:mm} · " +
                $"{FormatByteCount(entry.ByteCount)} · " +
                $"记录 {entry.OpaqueId[..12]} · {state}");
        }
        ContinuitySummaryText.Text = snapshot.Entries.Count == 0
            ? "没有找到固定日期目录中的本机历史记录；未读取会话正文。"
            : $"找到 {snapshot.Entries.Count} 条本机历史元数据；未读取提示词、回复或工具正文。";
        StatusBar.Severity = InfoBarSeverity.Success;
        StatusBar.Title = "历史元数据已刷新";
        StatusBar.Message = "没有复制会话、建立云索引或上传内容。";
    }

    private async Task<ContinuityFieldSelection?> ShowFieldSelectionAsync(
        WindowsContinuityImportSession session)
    {
        var relay = FieldCheckBox(
            "新增中转资料（每条重新录入凭据）",
            HasAction(session, WindowsContinuityScope.Relay));
        var workspace = FieldCheckBox(
            "工作区标签（映射到现有本机收藏）",
            HasAction(session, WindowsContinuityScope.Workspace));
        var start = FieldCheckBox(
            "启动入口偏好",
            HasAction(session, "start_destination"));
        var history = FieldCheckBox(
            "历史分组偏好",
            HasAction(session, "history_grouping"));
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock
        {
            Text = "选择本次要迁移的非敏感字段。当前接入、Codex 配置和验证状态不会迁移。",
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(relay);
        panel.Children.Add(workspace);
        panel.Children.Add(start);
        panel.Children.Add(history);
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "选择迁移内容",
            Content = panel,
            PrimaryButtonText = "继续逐项设置",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return null;
        }
        return new ContinuityFieldSelection(
            relay.IsChecked == true,
            workspace.IsChecked == true,
            start.IsChecked == true,
            history.IsChecked == true);
    }

    private async Task<ContinuityDecisions?> CollectContinuityDecisionsAsync(
        WindowsContinuityImportSession session,
        WindowsContinuityTargetState target,
        ContinuityFieldSelection selection)
    {
        var relays = new List<WindowsContinuityRelayDecision>();
        var workspaces = new List<WindowsContinuityWorkspaceDecision>();
        try
        {
            if (selection.Relays)
            {
                var addIds = session.Preview.Changes
                    .Where(change =>
                        change.Scope == WindowsContinuityScope.Relay &&
                        change.Disposition == WindowsContinuityDisposition.Add)
                    .Select(change => Guid.Parse(change.Id))
                    .ToHashSet();
                foreach (var profile in session.Manifest.AccessProfiles.Where(
                    profile => addIds.Contains(profile.Id)))
                {
                    var decision = await ShowRelayDecisionAsync(profile);
                    if (decision is null)
                    {
                        ZeroRelayDecisions(relays);
                        return null;
                    }
                    relays.Add(decision);
                }
            }

            if (selection.Workspaces)
            {
                var mapIds = session.Preview.Changes
                    .Where(change =>
                        change.Scope == WindowsContinuityScope.Workspace &&
                        change.Disposition ==
                            WindowsContinuityDisposition.NeedsMapping)
                    .Select(change => Guid.Parse(change.Id))
                    .ToHashSet();
                var available = target.FavoriteWorkspacePaths
                    .Where(path => !target.WorkspaceLabels.ContainsKey(path))
                    .ToList();
                foreach (var label in session.Manifest.WorkspaceLabels.Where(
                    label => mapIds.Contains(label.Id)))
                {
                    if (available.Count == 0)
                    {
                        throw new WindowsContinuityManifestException(
                            "No unused local favorite is available for workspace mapping.");
                    }
                    var selected = await ShowWorkspaceDecisionAsync(
                        label,
                        available);
                    if (selected is null)
                    {
                        ZeroRelayDecisions(relays);
                        return null;
                    }
                    workspaces.Add(new WindowsContinuityWorkspaceDecision(
                        label.Id,
                        selected));
                    available.RemoveAll(path => string.Equals(
                        path,
                        selected,
                        StringComparison.OrdinalIgnoreCase));
                }
            }
            return new ContinuityDecisions(relays, workspaces);
        }
        catch
        {
            ZeroRelayDecisions(relays);
            throw;
        }
    }

    private async Task<WindowsContinuityRelayDecision?> ShowRelayDecisionAsync(
        WindowsPortableAccessProfile profile)
    {
        var localId = new TextBox
        {
            Header = "本机资料标识",
            Text = $"import-{profile.Id:N}",
            MaxLength = 128,
        };
        AutomationProperties.SetName(localId, "本机中转资料标识");
        AutomationProperties.SetHelpText(
            localId,
            "只允许字母、数字、点、下划线和连字符，不会写入 Codex 配置。");
        var credential = new PasswordBox
        {
            Header = $"{profile.DisplayName} 的 API 凭据",
            PasswordRevealMode = PasswordRevealMode.Hidden,
        };
        AutomationProperties.SetName(
            credential,
            $"{profile.DisplayName} 的中转凭据");
        AutomationProperties.SetHelpText(
            credential,
            "仅保存到 AI接入助手专用 Windows Credential Manager 命名空间。");
        var panel = new StackPanel { Spacing = 8 };
        panel.Children.Add(new TextBlock
        {
            Text = $"新增“{profile.DisplayName}”。凭据只写入 AI接入助手专用 Windows Credential Manager 命名空间。",
            TextWrapping = TextWrapping.Wrap,
        });
        panel.Children.Add(localId);
        panel.Children.Add(credential);
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "重新录入中转凭据",
            Content = panel,
            PrimaryButtonText = "保存本条选择",
            CloseButtonText = "取消迁移",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            credential.Password = string.Empty;
            return null;
        }
        var identifier = localId.Text.Trim();
        var secretText = credential.Password;
        credential.Password = string.Empty;
        var secret = Encoding.UTF8.GetBytes(secretText);
        secretText = string.Empty;
        if (!IsSafeLocalProfileId(identifier) ||
            secret.Length is < 1 or >
                WindowsNativeTransactionContract.MaximumCredentialBytes)
        {
            CryptographicOperations.ZeroMemory(secret);
            throw new WindowsContinuityManifestException(
                "Relay identifier or credential is invalid.");
        }
        return new WindowsContinuityRelayDecision(
            profile.Id,
            identifier,
            secret);
    }

    private async Task<string?> ShowWorkspaceDecisionAsync(
        WindowsPortableWorkspaceLabel label,
        IReadOnlyList<string> favorites)
    {
        var picker = new ComboBox
        {
            Header = $"“{label.Label}”对应哪个本机收藏？",
            ItemsSource = favorites.ToArray(),
            SelectedIndex = 0,
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        AutomationProperties.SetName(
            picker,
            $"{label.Label} 的本机收藏映射");
        AutomationProperties.SetHelpText(
            picker,
            "只可选择已有本机收藏，不会导入源设备路径。");
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "映射工作区标签",
            Content = picker,
            PrimaryButtonText = "保存映射",
            CloseButtonText = "取消迁移",
            DefaultButton = ContentDialogButton.Close,
        };
        if (await dialog.ShowAsync() != ContentDialogResult.Primary)
        {
            return null;
        }
        return picker.SelectedItem as string;
    }

    private async Task<bool> ConfirmContinuityApplyAsync(
        ContinuityDecisions decisions,
        ContinuityFieldSelection selection)
    {
        var preferenceCount =
            (selection.StartDestination ? 1 : 0) +
            (selection.HistoryGrouping ? 1 : 0);
        var dialog = new ContentDialog
        {
            XamlRoot = RootGrid.XamlRoot,
            Title = "最终确认迁移？",
            Content =
                $"将新增 {decisions.Relays.Count} 个中转资料、映射 " +
                $"{decisions.Workspaces.Count} 个工作区标签并应用 " +
                $"{preferenceCount} 项偏好。当前接入和 Codex 配置保持不变；不会联网、验证或自动重试。",
            PrimaryButtonText = "确认写入非敏感设置",
            CloseButtonText = "取消",
            DefaultButton = ContentDialogButton.Close,
        };
        return await dialog.ShowAsync() == ContentDialogResult.Primary;
    }

    private void RefreshRecoveryIndicator()
    {
        try
        {
            var phase = ContinuityCoordinator.PendingRecoveryPhase();
            var pending = phase is not null;
            RecoverContinuityButton.Visibility = pending
                ? Visibility.Visible
                : Visibility.Collapsed;
            RecoverContinuityButton.IsEnabled = pending;
            ImportContinuityButton.IsEnabled = !pending;
            if (pending)
            {
                ContinuitySummaryText.Text =
                    "检测到未完成迁移。先使用“恢复上次迁移”；新的导入已阻止。";
                ContinuityEvidenceText.Text =
                    $"本机恢复阶段：{phase}。未显示路径、凭据或会话内容。";
            }
        }
        catch (Exception error) when (
            error is WindowsContinuityRecoveryRequiredException or
            IOException or
            UnauthorizedAccessException or
            ArgumentException or
            SecurityException)
        {
            RecoverContinuityButton.Visibility = Visibility.Visible;
            RecoverContinuityButton.IsEnabled = true;
            ImportContinuityButton.IsEnabled = false;
            ContinuitySummaryText.Text =
                "迁移恢复证据需要处理；新的导入已阻止。";
            PresentInclusiveFailure(
                error,
                WindowsInclusiveOperation.ContinuityRecovery);
        }
    }

    private static CheckBox FieldCheckBox(string title, bool actionable)
    {
        var checkBox = new CheckBox
        {
            Content = title,
            IsChecked = actionable,
            IsEnabled = actionable,
        };
        AutomationProperties.SetName(checkBox, title);
        AutomationProperties.SetHelpText(
            checkBox,
            actionable
                ? "按空格选择或取消本类非敏感迁移内容。"
                : "本类没有可迁移变化。不可选择。");
        return checkBox;
    }

    private static bool HasAction(
        WindowsContinuityImportSession session,
        WindowsContinuityScope scope) =>
        session.Preview.Changes.Any(change =>
            change.Scope == scope &&
            change.Disposition is WindowsContinuityDisposition.Add or
                WindowsContinuityDisposition.NeedsMapping);

    private static bool HasAction(
        WindowsContinuityImportSession session,
        string field) =>
        session.Preview.Changes.Any(change =>
            change.Field == field &&
            change.Disposition == WindowsContinuityDisposition.ApplyPreference);

    private static string DescribePreview(WindowsContinuityPreview preview)
    {
        var lines = new List<string>
        {
            $"来源：{preview.SourcePlatform} · {preview.SourceVersion} ({preview.SourceBuild})",
        };
        lines.AddRange(preview.Changes.Select(change =>
            $"{DispositionText(change.Disposition)} · {change.Title}"));
        lines.AddRange(preview.Warnings.Select(warning => $"注意 · {warning}"));
        return string.Join(Environment.NewLine, lines);
    }

    private static string DispositionText(
        WindowsContinuityDisposition disposition) => disposition switch
    {
        WindowsContinuityDisposition.NoChange => "无需变化",
        WindowsContinuityDisposition.Add => "可新增",
        WindowsContinuityDisposition.Conflict => "冲突，已阻止",
        WindowsContinuityDisposition.NeedsMapping => "需要本机映射",
        WindowsContinuityDisposition.ApplyPreference => "可应用偏好",
        _ => "未知",
    };

    private static bool IsSafeLocalProfileId(string value) =>
        value.Length is >= 1 and <= 128 &&
        value.All(character =>
            char.IsAsciiLetterOrDigit(character) ||
            character is '.' or '_' or '-');

    private static void ZeroRelayDecisions(
        IEnumerable<WindowsContinuityRelayDecision> decisions)
    {
        foreach (var decision in decisions)
        {
            CryptographicOperations.ZeroMemory(decision.CredentialUtf8);
        }
    }

    private static string FormatByteCount(long value) => value switch
    {
        >= 1024 * 1024 => $"{value / (1024d * 1024d):0.0} MiB",
        >= 1024 => $"{value / 1024d:0.0} KiB",
        _ => $"{value} B",
    };

    private void RestoreVerificationButton(WindowsVerificationStep step)
    {
        BasicVerificationButton.IsEnabled =
            step == WindowsVerificationStep.BasicConnection;
        RealTaskVerificationButton.IsEnabled =
            step == WindowsVerificationStep.RealTask;
    }

    private void InvalidateReadinessAfterFailure()
    {
        _readinessSnapshot = null;
        CanWorkText.Text = "当前能否工作尚未确认";
        InstallationText.Text = string.Empty;
        AccessText.Text = string.Empty;
        PathText.Text = "尚未确认配置路径";
        BasicVerificationButton.IsEnabled = false;
        RealTaskVerificationButton.IsEnabled = false;
        VerificationStageText.Text =
            "当前状态读取失败；处理唯一动作后重新刷新只读识别。";
    }

    private static WindowsInclusiveOperation InclusiveOperationFor(
        WindowsVerificationStep step) =>
        step == WindowsVerificationStep.BasicConnection
            ? WindowsInclusiveOperation.BasicVerification
            : WindowsInclusiveOperation.RealTaskVerification;

    private void PresentInclusiveFailure(
        Exception error,
        WindowsInclusiveOperation operation)
    {
        var presentation =
            WindowsInclusiveFailureProjector.Project(error, operation);
        StatusBar.Severity = InfoBarSeverity.Warning;
        StatusBar.Title = presentation.Conclusion;
        StatusBar.Message = presentation.Continuation;
        PrimaryActionText.Text = presentation.PrimaryAction;
        ContinuationText.Text = presentation.Continuation;
    }

    private static void RestoreKeyboardFocus(
        Control preferred,
        Control fallback)
    {
        var target = preferred.IsEnabled &&
                preferred.Visibility == Visibility.Visible
            ? preferred
            : fallback.IsEnabled && fallback.Visibility == Visibility.Visible
                ? fallback
                : null;
        _ = target?.Focus(FocusState.Programmatic);
    }
}
