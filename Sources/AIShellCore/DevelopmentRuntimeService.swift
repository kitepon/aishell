import CryptoKit
import Foundation

public actor DevelopmentRuntimeService {
    private let runtimeStore: RuntimeStore
    private var managedArtifacts: ManagedRunArtifactStore?
    private let processes: NativeProcessService
    public nonisolated let evidenceStore: EvidenceStore
    public nonisolated let workspaceRuntime: WorkspaceStateRuntime
    private let contextCompiler: ContextCompilerService
    private let focusedChecks: FocusedCheckService
    private let freshnessCache: CheckFreshnessCache
    private let projectProfiles: ProjectProfileService
    private let runCheckResolution: RunCheckResolutionService
    private let changeImpactService: ChangeImpactService
    private let semanticSearchContextService: SemanticSearchContextService

    public init(
        runtimeStore: RuntimeStore = RuntimeStore(),
        evidenceStore: EvidenceStore? = nil,
        workspaceRuntime: WorkspaceStateRuntime? = nil,
        focusedChecks: FocusedCheckService? = nil,
        freshnessCache: CheckFreshnessCache? = nil,
        projectProfiles: ProjectProfileService? = nil,
        changeImpactService: ChangeImpactService? = nil
    ) {
        self.runtimeStore = runtimeStore
        processes = NativeProcessService(store: runtimeStore)
        self.evidenceStore = evidenceStore ?? EvidenceStore(
            baseDirectory: runtimeStore.baseDirectory.appendingPathComponent("evidence", isDirectory: true)
        )
        let workspace = workspaceRuntime ?? WorkspaceStateRuntime(runtimeStore: runtimeStore)
        self.workspaceRuntime = workspace
        let focused = focusedChecks ?? FocusedCheckService()
        self.focusedChecks = focused
        let profiles = projectProfiles ?? ProjectProfileService(
            runtimeStore: runtimeStore,
            workspaceRuntime: workspace,
            evidenceStore: self.evidenceStore
        )
        self.projectProfiles = profiles
        runCheckResolution = RunCheckResolutionService(
            projectProfiles: profiles,
            workspaceRuntime: workspace
        )
        let productionImpactProviders: [any ChangeImpactProvider] = [
            FileSystemChangeImpactProvider(),
            StaticImportChangeImpactProvider(),
            DepfileChangeImpactProvider(),
            BuildManifestChangeImpactProvider(),
            SourceKitChangeImpactProvider(service: SourceKitLSPService(
                runtimeStore: runtimeStore,
                workspaceRuntime: workspace
            )),
        ]
        self.changeImpactService = changeImpactService ?? ChangeImpactService(
            runtimeStore: runtimeStore,
            workspaceRuntime: workspace,
            evidenceStore: self.evidenceStore,
            providers: productionImpactProviders,
            focusedCheckService: focused
        )
        semanticSearchContextService = SemanticSearchContextService(
            runtimeStore: runtimeStore,
            workspaceRuntime: workspace,
            evidenceStore: self.evidenceStore
        )
        contextCompiler = ContextCompilerService(
            runtimeStore: runtimeStore,
            workspaceRuntime: workspace,
            evidenceStore: self.evidenceStore,
            projectProfileService: profiles
        )
        self.freshnessCache = freshnessCache ?? CheckFreshnessCache(
            storeDirectory: runtimeStore.baseDirectory.appendingPathComponent("check-freshness-cache", isDirectory: true)
        )
    }

    /// 公開run_check用入口。caller supplied catalogや再観測closureを受けず、
    /// AIShellが所有するProjectProfile/Direct OS/focused registryから実行contextを作る。
    public func runCheck(
        plan: RunCheckInvocationPlan,
        focusedSetDigest: String? = nil,
        environment: [String: String] = [:]
    ) async throws -> RunCheckPipelineResult {
        guard case .sync = plan.dispatch else {
            throw RunCheckPipelineError.dispatchNotReady(processesStarted: 0)
        }
        let resolution: RunCheckResolutionContext
        do {
            resolution = try await currentResolutionContext(
                for: plan,
                focusedSetDigest: focusedSetDigest,
                environment: environment
            )
        } catch let error as RunCheckPipelineError {
            throw error
        } catch is ProjectProfileResolutionError {
            throw RunCheckPipelineError.selectionStale(processesStarted: 0)
        } catch let error as AIShellError {
            if case .contentChanged = error {
                throw RunCheckPipelineError.contentChanged(processesStarted: 0)
            }
            throw error
        }
        return try await runCheck(plan: plan, resolution: resolution)
    }

    /// recommendが返したimmutable setからcallerが選んだID列のselection digestをCoreで
    /// 生成する公開入口。既存のverify_focused_set経路はexpected digestを渡して維持する。
    public func runFocusedCheck(
        invocation: RunCheckInvocationPlan.Invocation,
        dispatch: RunCheckInvocationPlan.Dispatch,
        cachePolicy: RunCheckInvocationPlan.CachePolicy,
        executionPolicy: RunCheckInvocationPlan.ExecutionPolicy,
        focusedSetDigest: String,
        expectedSelectionDigest: String? = nil
    ) async throws -> RunCheckPipelineResult {
        guard case .sync = dispatch else {
            throw RunCheckPipelineError.dispatchNotReady(processesStarted: 0)
        }
        guard case .focusedSet(let requested) = invocation else {
            throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
        }
        let prepared: FocusedCheckService.PreparedSetReceipt
        do {
            prepared = try await focusedChecks.prepare(
                focusedSetID: requested.setID,
                focusedSetDigest: focusedSetDigest
            )
        } catch {
            throw RunCheckPipelineError.selectionStale(processesStarted: 0)
        }
        let exact: ProjectProfileResolution
        do {
            exact = try await projectProfiles.resolveExactProfile(
                profileDigest: prepared.profileDigest,
                sinceCursor: prepared.cursor
            )
        } catch is ProjectProfileResolutionError {
            throw RunCheckPipelineError.selectionStale(processesStarted: 0)
        } catch let error as AIShellError {
            if case .contentChanged = error {
                throw RunCheckPipelineError.contentChanged(processesStarted: 0)
            }
            throw error
        }
        guard exact.observedCursor == prepared.cursor,
              exact.profile.projectRootIdentity == prepared.rootIdentity,
              let manifest = exact.profile.manifests.first(where: {
                  $0.identity == prepared.manifestIdentity
              }) else {
            throw RunCheckPipelineError.selectionStale(processesStarted: 0)
        }
        let admission = FocusedCheckService.Admission(
            rootIdentity: exact.profile.projectRootIdentity,
            generation: try workspaceGeneration(from: exact.observedCursor),
            cursor: exact.observedCursor,
            profileDigest: exact.profile.profileDigest,
            manifestIdentity: manifest.identity,
            impactArtifactDigest: prepared.impactArtifactDigest
        )
        let selection: FocusedCheckService.Selection
        do {
            if let expectedSelectionDigest {
                selection = try await focusedChecks.resolve(
                    focusedSetID: requested.setID,
                    focusedSetDigest: focusedSetDigest,
                    requestedCheckIDs: requested.orderedCheckIDs,
                    expectedSelectionDigest: expectedSelectionDigest,
                    admission: admission
                )
            } else {
                selection = try await focusedChecks.resolve(
                    focusedSetID: requested.setID,
                    focusedSetDigest: focusedSetDigest,
                    requestedCheckIDs: requested.orderedCheckIDs,
                    admission: admission
                )
            }
        } catch let error as FocusedCheckService.Error {
            switch error {
            case .invocationInvalid:
                throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
            case .selectionStale:
                throw RunCheckPipelineError.selectionStale(processesStarted: 0)
            }
        }
        let plan = try RunCheckInvocationPlan.compile(.v2(.init(
            invocation: invocation,
            dispatch: dispatch,
            cachePolicy: cachePolicy,
            executionPolicy: executionPolicy,
            selectionDigest: selection.selectionDigest
        )))
        return try await runCheck(plan: plan, focusedSetDigest: focusedSetDigest)
    }

    public func runCheck(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        environment: [String: String] = [:],
        timeoutSeconds: Double = 120,
        retentionSeconds: TimeInterval = EvidenceStore.defaultRetentionSeconds
    ) async throws -> RunCheckResult {
        _ = try RunCheckInvocationPlan.compile(.legacyDirect(.init(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            effectiveEnvironment: environment,
            executionPolicy: .init(
                timeoutMilliseconds: UInt64(max(1, timeoutSeconds * 1_000)),
                retentionSeconds: UInt64(max(1, retentionSeconds))
            )
        )))
        return try await executeDirect(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds,
            retentionSeconds: retentionSeconds
        )
    }

    /// ADR 0018-0020 のimmutable planを、exact profile/focused selection、cache、sync executionへ接続する。
    public func runCheck(
        plan: RunCheckInvocationPlan,
        resolution: RunCheckResolutionContext
    ) async throws -> RunCheckPipelineResult {
        guard case .sync = plan.dispatch else {
            throw RunCheckPipelineError.dispatchNotReady(processesStarted: 0)
        }

        let resolved = try await resolve(plan: plan, context: resolution)
        let cacheRequest = CheckFreshnessCache.Request(
            policy: cachePolicy(plan.cachePolicy),
            plan: .init(
                invocationID: plan.digest,
                orderedStepIDs: resolved.steps.map(\.stepID),
                selectionDigest: resolved.selectionDigest
            ),
            orderedSteps: resolved.steps.map { .init(id: $0.stepID, binding: $0.binding) }
        )
        let evidenceStore = self.evidenceStore
        let processCounter = RunCheckProcessCounter()
        do {
            let outcome = try await freshnessCache.execute(
                cacheRequest,
                executeUncached: { [processes, evidenceStore] cacheSteps in
                    var results: [CheckFreshnessCache.Result] = []
                    var nonPassingStepIDs = Set<String>()
                    var processesStarted = 0
                    for cacheStep in cacheSteps {
                        guard let step = resolved.steps.first(where: { $0.stepID == cacheStep.id }) else {
                            throw RunCheckPipelineError.invocationInvalid(processesStarted: processesStarted)
                        }
                        if step.dependsOn.contains(where: { nonPassingStepIDs.contains($0) }) {
                            results.append(Self.skippedCacheResult(stepID: step.stepID))
                            nonPassingStepIDs.insert(step.stepID)
                            continue
                        }
                        let execution = try await processes.runRetained(
                            executable: step.executable,
                            arguments: step.arguments,
                            workingDirectory: step.workingDirectory,
                            environment: step.environment,
                            timeoutSeconds: Double(plan.executionPolicy.timeoutMilliseconds) / 1_000,
                            evidenceStore: evidenceStore,
                            retentionSeconds: TimeInterval(plan.executionPolicy.retentionSeconds)
                        )
                        let result = Self.cacheResult(stepID: step.stepID, execution: execution)
                        results.append(result)
                        processesStarted += 1
                        processCounter.increment()
                        if result.terminalState != .passed { nonPassingStepIDs.insert(step.stepID) }
                    }
                    return .init(results: results, processesStarted: processesStarted)
                },
                validateBindingAfterExecution: { steps in
                    guard steps.count == resolved.steps.count else { return false }
                    for (cached, execution) in zip(steps, resolved.steps) {
                        guard cached.id == execution.stepID,
                              cached.binding == execution.binding,
                              await execution.reobserveBinding() == cached.binding else {
                            return false
                        }
                    }
                    return true
                },
                verifyArtifact: { artifact in
                    if artifact.expiresAt <= Date() { return .expired }
                    do {
                        _ = try await evidenceStore.verifyCompleteArtifact(
                            handle: artifact.handle,
                            kind: artifact.kind,
                            producer: artifact.producer,
                            sha256: artifact.sha256
                        )
                        return .valid
                    } catch {
                        return .corrupt
                    }
                }
            )
            var diagnostics: DiagnosticAdapterResult?
            if case let .direct(direct) = plan.invocation, let format = direct.diagnosticFormat {
                guard let root = direct.workingDirectory,
                      let stdout = outcome.results.first?.artifacts.first(where: { $0.kind == "stdout" }) else {
                    throw RunCheckPipelineError.invocationInvalid(processesStarted: processCounter.value)
                }
                let data = try await evidenceStore.completeData(handle: stdout.handle, maximumBytes: 64 * 1_024 * 1_024)
                diagnostics = try DiagnosticAdapterService().parse(
                    format: format,
                    data: data,
                    root: URL(fileURLWithPath: root, isDirectory: true)
                )
            }
            return RunCheckPipelineResult(
                schemaVersion: "aishell.run-check.v2",
                planDigest: plan.digest,
                selectionDigest: resolved.selectionDigest,
                requestedCheckIDs: resolved.requestedCheckIDs,
                plannedCheckIDs: resolved.plannedCheckIDs,
                cacheState: outcome.state,
                processesStarted: outcome.processesStarted,
                publications: outcome.publications,
                steps: outcome.results.map(RunCheckPipelineStepResult.init),
                lookupEvidence: outcome.lookupEvidence,
                diagnostics: diagnostics
            )
        } catch let error as CheckFreshnessCache.Error {
            throw Self.pipelineError(error, processesStarted: processCounter.value)
        }
    }

    private func executeDirect(
        executable: String,
        arguments: [String],
        workingDirectory: String?,
        environment: [String: String],
        timeoutSeconds: Double,
        retentionSeconds: TimeInterval
    ) async throws -> RunCheckResult {
        let requestID = "req_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let execution = try await processes.runRetained(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: environment,
            timeoutSeconds: timeoutSeconds,
            evidenceStore: evidenceStore,
            retentionSeconds: retentionSeconds
        )

        let status: RunCheckStatus
        if execution.timedOut {
            status = .timedOut
        } else if execution.exitCode == 0 {
            status = .passed
        } else {
            status = .failed
        }
        let diagnostic = try await primaryDiagnostic(for: execution)
        let summary: String
        switch status {
        case .passed:
            summary = "成功: exit 0"
        case .failed:
            summary = diagnostic.map { "失敗: \($0)" } ?? "失敗: exit \(execution.exitCode)"
        case .timedOut:
            summary = "timeout: \(execution.durationMilliseconds)ms"
        }

        return RunCheckResult(
            schemaVersion: "aishell.run-check.v1",
            requestID: requestID,
            status: status,
            summary: summary,
            primaryDiagnostic: diagnostic,
            exitCode: execution.exitCode,
            timedOut: execution.timedOut,
            durationMilliseconds: execution.durationMilliseconds,
            stdoutArtifact: execution.stdoutArtifact,
            stderrArtifact: execution.stderrArtifact
        )
    }

    private struct ResolvedExecutionStep: Sendable {
        let stepID: String
        let dependsOn: [String]
        let executable: String
        let arguments: [String]
        let workingDirectory: String?
        let environment: [String: String]
        let binding: CheckFreshnessCache.Binding
        let reobserveBinding: @Sendable () async -> CheckFreshnessCache.Binding
    }

    private struct ResolvedInvocation: Sendable {
        let requestedCheckIDs: [String]
        let plannedCheckIDs: [String]
        let selectionDigest: String
        let steps: [ResolvedExecutionStep]
    }

    private func currentResolutionContext(
        for plan: RunCheckInvocationPlan,
        focusedSetDigest: String?,
        environment: [String: String]
    ) async throws -> RunCheckResolutionContext {
        switch plan.invocation {
        case .direct:
            guard focusedSetDigest == nil else {
                throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
            }
            return RunCheckResolutionContext(
                profileCatalog: .init(
                    schemaVersion: "aishell.project-profile-catalog.v1",
                    root: "",
                    observedCursor: "",
                    profiles: [],
                    computedProfiles: 0,
                    cachedProfiles: 0
                ),
                environment: environment
            )

        case .profileCheck(let requested):
            guard focusedSetDigest == nil else {
                throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
            }
            let exact = try await projectProfiles.resolveExactCheck(
                projectID: requested.projectID,
                profileDigest: requested.profileDigest,
                checkID: requested.checkID
            )
            let receipt = try await runCheckResolution.resolve(.init(
                projectID: requested.projectID,
                profileDigest: requested.profileDigest,
                checkID: requested.checkID
            ))
            return RunCheckResolutionContext(
                profileCatalog: catalog(from: exact),
                environment: environment,
                relevantInputsByCheckID: [requested.checkID: relevantInputBinding(receipt)]
            )

        case .focusedSet(let requested):
            guard let focusedSetDigest else {
                throw RunCheckPipelineError.selectionStale(processesStarted: 0)
            }
            let prepared: FocusedCheckService.PreparedSetReceipt
            do {
                prepared = try await focusedChecks.prepare(
                    focusedSetID: requested.setID,
                    focusedSetDigest: focusedSetDigest
                )
            } catch {
                throw RunCheckPipelineError.selectionStale(processesStarted: 0)
            }
            let exact = try await projectProfiles.resolveExactProfile(
                profileDigest: prepared.profileDigest,
                sinceCursor: prepared.cursor
            )
            guard exact.observedCursor == prepared.cursor,
                  exact.profile.projectRootIdentity == prepared.rootIdentity,
                  let manifest = exact.profile.manifests.first(where: {
                      $0.identity == prepared.manifestIdentity
                  }) else {
                throw RunCheckPipelineError.selectionStale(processesStarted: 0)
            }
            let admission = FocusedCheckService.Admission(
                rootIdentity: exact.profile.projectRootIdentity,
                generation: try workspaceGeneration(from: exact.observedCursor),
                cursor: exact.observedCursor,
                profileDigest: exact.profile.profileDigest,
                manifestIdentity: manifest.identity,
                impactArtifactDigest: prepared.impactArtifactDigest
            )
            let selection: FocusedCheckService.Selection
            do {
                selection = try await focusedChecks.resolve(
                    focusedSetID: requested.setID,
                    focusedSetDigest: focusedSetDigest,
                    requestedCheckIDs: requested.orderedCheckIDs,
                    expectedSelectionDigest: plan.selectionDigest,
                    admission: admission
                )
            } catch let error as FocusedCheckService.Error {
                switch error {
                case .invocationInvalid:
                    throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
                case .selectionStale:
                    throw RunCheckPipelineError.selectionStale(processesStarted: 0)
                }
            }
            var relevant: [String: RunCheckRelevantInputBinding] = [:]
            for checkID in Set(selection.resolvedCandidates.map(\.profileCheckID)).sorted() {
                let receipt = try await runCheckResolution.resolve(.init(
                    projectID: exact.profile.projectId,
                    profileDigest: exact.profile.profileDigest,
                    checkID: checkID
                ))
                relevant[checkID] = relevantInputBinding(receipt)
            }
            return RunCheckResolutionContext(
                profileCatalog: .init(
                    schemaVersion: "aishell.project-profile-catalog.v1",
                    root: exact.catalogRoot,
                    observedCursor: exact.observedCursor,
                    profiles: [exact.profile],
                    computedProfiles: 1,
                    cachedProfiles: 0
                ),
                focusedAdmission: admission,
                environment: environment,
                relevantInputsByCheckID: relevant
            )
        }
    }

    private func catalog(from resolution: ProjectProfileCheckResolution) -> ProjectProfileCatalogResult {
        .init(
            schemaVersion: "aishell.project-profile-catalog.v1",
            root: resolution.catalogRoot,
            observedCursor: resolution.observedCursor,
            profiles: [resolution.profile],
            computedProfiles: 1,
            cachedProfiles: 0
        )
    }

    private func relevantInputBinding(
        _ receipt: RunCheckRelevantInputReceipt
    ) -> RunCheckRelevantInputBinding {
        RunCheckRelevantInputBinding(
            digest: receipt.bindingDigest,
            reobserveDigest: { [runCheckResolution] in
                try await runCheckResolution.reobserve(receipt).bindingDigest
            }
        )
    }

    private func workspaceGeneration(from cursor: String) throws -> String {
        let parts = cursor.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[0] == "ws2", !parts[3].isEmpty,
              UInt64(parts[4]) != nil else {
            throw RunCheckPipelineError.selectionStale(processesStarted: 0)
        }
        return String(parts[3])
    }

    private func resolve(
        plan: RunCheckInvocationPlan,
        context: RunCheckResolutionContext
    ) async throws -> ResolvedInvocation {
        switch plan.invocation {
        case .direct(let direct):
            guard plan.cachePolicy == .off else {
                throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
            }
            return ResolvedInvocation(
                requestedCheckIDs: [],
                plannedCheckIDs: [],
                selectionDigest: plan.selectionDigest,
                steps: [.init(
                    stepID: "direct",
                    dependsOn: [],
                    executable: direct.executable,
                    arguments: direct.arguments,
                    workingDirectory: direct.workingDirectory,
                    environment: direct.effectiveEnvironment,
                    binding: .ineligible(reason: .unsupported),
                    reobserveBinding: { .ineligible(reason: .unsupported) }
                )]
            )

        case .profileCheck(let requested):
            guard let profile = exactProfile(
                projectID: requested.projectID,
                profileDigest: requested.profileDigest,
                in: context.profileCatalog
            ), let descriptor = exactCheck(requested.checkID, in: profile) else {
                throw RunCheckPipelineError.selectionStale(processesStarted: 0)
            }
            let step = try resolvedStep(
                stepID: descriptor.checkId,
                dependsOn: [],
                descriptor: descriptor,
                selector: .profileCheck(id: descriptor.checkId),
                profile: profile,
                environment: context.environment,
                catalogRoot: context.profileCatalog.root,
                relevantInput: context.relevantInputsByCheckID[descriptor.checkId],
                executionPolicy: plan.executionPolicy
            )
            return ResolvedInvocation(
                requestedCheckIDs: [requested.checkID],
                plannedCheckIDs: [requested.checkID],
                selectionDigest: plan.selectionDigest,
                steps: [step]
            )

        case .focusedSet(let requested):
            guard let admission = context.focusedAdmission else {
                throw RunCheckPipelineError.selectionStale(processesStarted: 0)
            }
            let selection: FocusedCheckService.Selection
            do {
                selection = try await focusedChecks.resolve(
                    focusedSetID: requested.setID,
                    requestedCheckIDs: requested.orderedCheckIDs,
                    expectedSelectionDigest: plan.selectionDigest,
                    admission: admission
                )
            } catch let error as FocusedCheckService.Error {
                switch error {
                case .invocationInvalid:
                    throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
                case .selectionStale:
                    throw RunCheckPipelineError.selectionStale(processesStarted: 0)
                }
            }
            guard selection.requestedCheckIDs == requested.orderedCheckIDs,
                  selection.plannedCheckIDs == requested.orderedCheckIDs,
                  context.profileCatalog.observedCursor == admission.cursor,
                  selection.steps.map(\.id) == selection.resolvedCandidates.flatMap({ $0.steps.map(\.id) }) else {
                throw RunCheckPipelineError.selectionStale(processesStarted: 0)
            }
            var steps: [ResolvedExecutionStep] = []
            for candidate in selection.resolvedCandidates {
                let matchingProfiles = context.profileCatalog.profiles.filter {
                    $0.profileDigest == admission.profileDigest
                        && $0.projectRootIdentity == admission.rootIdentity
                        && $0.observedCursor == admission.cursor
                        && $0.manifests.contains(where: { $0.identity == admission.manifestIdentity })
                        && exactCheck(candidate.profileCheckID, in: $0) != nil
                }
                guard matchingProfiles.count == 1,
                      let profile = matchingProfiles.first,
                      let descriptor = exactCheck(candidate.profileCheckID, in: profile) else {
                    throw RunCheckPipelineError.selectionStale(processesStarted: 0)
                }
                for publishedStep in candidate.steps {
                    steps.append(try resolvedStep(
                        stepID: publishedStep.id,
                        dependsOn: publishedStep.dependsOn,
                        descriptor: descriptor,
                        selector: candidate.selector,
                        profile: profile,
                        environment: context.environment,
                        catalogRoot: context.profileCatalog.root,
                        relevantInput: context.relevantInputsByCheckID[descriptor.checkId],
                        executionPolicy: plan.executionPolicy
                    ))
                }
            }
            guard steps.map(\.stepID) == selection.steps.map(\.id) else {
                throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
            }
            return ResolvedInvocation(
                requestedCheckIDs: selection.requestedCheckIDs,
                plannedCheckIDs: selection.plannedCheckIDs,
                selectionDigest: selection.selectionDigest,
                steps: steps
            )
        }
    }

    private func exactProfile(
        projectID: String,
        profileDigest: String,
        in catalog: ProjectProfileCatalogResult
    ) -> ProjectProfile? {
        let matches = catalog.profiles.filter {
            $0.projectId == projectID && $0.profileDigest == profileDigest
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private func exactCheck(_ checkID: String, in profile: ProjectProfile) -> ProjectProfileCheck? {
        let matches = profile.checks.filter { $0.checkId == checkID }
        return matches.count == 1 ? matches[0] : nil
    }

    private func resolvedStep(
        stepID: String,
        dependsOn: [String],
        descriptor: ProjectProfileCheck,
        selector: FocusedCheckService.Selector,
        profile: ProjectProfile,
        environment: [String: String],
        catalogRoot: String,
        relevantInput: RunCheckRelevantInputBinding?,
        executionPolicy: RunCheckInvocationPlan.ExecutionPolicy
    ) throws -> ResolvedExecutionStep {
        let arguments: [String]
        switch selector {
        case .profileCheck(let id):
            guard id == descriptor.checkId else {
                throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
            }
            arguments = descriptor.arguments
        case .testPath(let path):
            guard descriptor.kind == "test" else {
                throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
            }
            switch profile.ecosystem {
            case "npm": arguments = descriptor.arguments + [path]
            case "swiftpm": arguments = descriptor.arguments + ["--filter", path]
            default: throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
            }
        case .target:
            // target selectorを全testへ拡張しない。対応するexact adapterは別契約で追加する。
            throw RunCheckPipelineError.invocationInvalid(processesStarted: 0)
        }

        let effectiveEnvironment = ProcessInfo.processInfo.environment.merging(environment) { _, override in override }
        let binding = try Self.freshnessBinding(
            descriptor: descriptor,
            arguments: arguments,
            profile: profile,
            environment: effectiveEnvironment,
            catalogRoot: catalogRoot,
            relevantInputDigest: relevantInput?.digest,
            executionPolicy: executionPolicy
        )
        let capturedDescriptor = descriptor
        let capturedArguments = arguments
        let capturedProfile = profile
        let capturedEnvironmentOverrides = environment
        let capturedCatalogRoot = catalogRoot
        let capturedRelevantInput = relevantInput
        let capturedPolicy = executionPolicy
        return .init(
            stepID: stepID,
            dependsOn: dependsOn,
            executable: descriptor.executable,
            arguments: arguments,
            workingDirectory: descriptor.workingDirectory,
            environment: effectiveEnvironment,
            binding: binding,
            reobserveBinding: {
                (try? Self.freshnessBinding(
                    descriptor: capturedDescriptor,
                    arguments: capturedArguments,
                    profile: capturedProfile,
                    environment: ProcessInfo.processInfo.environment.merging(capturedEnvironmentOverrides) { _, override in override },
                    catalogRoot: capturedCatalogRoot,
                    relevantInputDigest: try? await capturedRelevantInput?.reobserveDigest(),
                    executionPolicy: capturedPolicy
                )) ?? .ineligible(reason: .bindingUnavailable)
            }
        )
    }

    private nonisolated static func freshnessBinding(
        descriptor: ProjectProfileCheck,
        arguments: [String],
        profile: ProjectProfile,
        environment: [String: String],
        catalogRoot: String,
        relevantInputDigest: String?,
        executionPolicy: RunCheckInvocationPlan.ExecutionPolicy
    ) throws -> CheckFreshnessCache.Binding {
        let executable = URL(fileURLWithPath: descriptor.executable).resolvingSymlinksInPath()
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              !profile.binding.isEmpty, !profile.manifests.isEmpty, !profile.toolchains.isEmpty,
              let relevantInputDigest, Self.isSHA256(relevantInputDigest) else {
            return .ineligible(reason: .bindingIncomplete)
        }
        let bytes = try Data(contentsOf: executable, options: .mappedIfSafe)
        let attributes = try FileManager.default.attributesOfItem(atPath: executable.path)
        let executableIdentity = [
            executable.path,
            String(describing: attributes[.systemNumber] ?? ""),
            String(describing: attributes[.systemFileNumber] ?? ""),
            String(describing: attributes[.posixPermissions] ?? ""),
            sha256(bytes),
        ]
        var fields = [
            "schema", "aishell.run-check-binding.v1",
            "check", descriptor.checkId,
            "profile", profile.profileDigest,
            "profile_binding", profile.binding,
            "project_root_identity", profile.projectRootIdentity,
            "relevant_input_closure", relevantInputDigest,
            "cwd", descriptor.workingDirectory,
            "timeout_ms", String(executionPolicy.timeoutMilliseconds),
            "retention_s", String(executionPolicy.retentionSeconds),
        ] + executableIdentity
        fields += ["arguments", String(arguments.count)] + arguments
        for manifest in profile.manifests.sorted(by: { $0.path < $1.path }) {
            let url = URL(fileURLWithPath: catalogRoot, isDirectory: true).appendingPathComponent(manifest.path)
            guard let liveBytes = try? Data(contentsOf: url, options: .mappedIfSafe),
                  sha256(liveBytes) == manifest.sha256,
                  let liveAttributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  "\(liveAttributes[.systemNumber] ?? ""):\(liveAttributes[.systemFileNumber] ?? "")" == manifest.identity else {
                return .ineligible(reason: .bindingIncomplete)
            }
            fields += ["manifest", manifest.path, manifest.identity, manifest.sha256]
        }
        for toolchain in profile.toolchains.sorted(by: { $0.identity < $1.identity }) {
            let toolURL = URL(fileURLWithPath: toolchain.executable).resolvingSymlinksInPath()
            guard let toolBytes = try? Data(contentsOf: toolURL, options: .mappedIfSafe),
                  sha256(toolBytes) == toolchain.sha256,
                  let liveAttributes = try? FileManager.default.attributesOfItem(atPath: toolURL.path),
                  "\(liveAttributes[.systemNumber] ?? ""):\(liveAttributes[.systemFileNumber] ?? "")" == toolchain.identity else {
                return .ineligible(reason: .bindingIncomplete)
            }
            fields += ["toolchain", toolchain.identity, toolchain.sha256, toolchain.evidenceSHA256, toolchain.version]
        }
        for key in descriptor.environmentKeys.sorted() {
            fields += ["environment", key, environment[key].map { "set:\($0)" } ?? "absent"]
        }
        return .eligible(digest: digest(fields))
    }

    private static func cacheResult(
        stepID: String,
        execution: RetainedProcessExecution
    ) -> CheckFreshnessCache.Result {
        let terminal: CheckFreshnessCache.TerminalState = execution.timedOut
            ? .timedOut : (execution.exitCode == 0 ? .passed : .failed)
        let payload = digest([
            stepID, terminal.rawValue, String(execution.exitCode),
            execution.stdoutArtifact.sha256, execution.stderrArtifact.sha256,
        ])
        return .init(
            stepID: stepID,
            terminalState: terminal,
            sourceRunID: "run_\(execution.processIdentifier)",
            stdoutArtifactSHA256: execution.stdoutArtifact.sha256,
            stderrArtifactSHA256: execution.stderrArtifact.sha256,
            payloadDigest: payload,
            artifacts: [execution.stdoutArtifact, execution.stderrArtifact]
        )
    }

    private static func skippedCacheResult(stepID: String) -> CheckFreshnessCache.Result {
        let empty = sha256(Data())
        return .init(
            stepID: stepID,
            terminalState: .cancelled,
            sourceRunID: "skipped_dependency:\(stepID)",
            stdoutArtifactSHA256: empty,
            stderrArtifactSHA256: empty,
            payloadDigest: digest([stepID, "skipped_dependency"]),
            artifacts: []
        )
    }

    private func cachePolicy(_ policy: RunCheckInvocationPlan.CachePolicy) -> CheckFreshnessCache.Policy {
        switch policy {
        case .off: .off
        case .prefer: .prefer
        case .only: .only
        case .refresh: .refresh
        }
    }

    private static func pipelineError(
        _ error: CheckFreshnessCache.Error,
        processesStarted: Int
    ) -> RunCheckPipelineError {
        switch error {
        case .cacheMissWithEvidence(let evidence), .cacheExpiredWithEvidence(let evidence):
            .cacheMiss(processesStarted: processesStarted, evidence: evidence)
        case .cacheMiss, .cacheExpired:
            .cacheMiss(processesStarted: processesStarted, evidence: [])
        case .cacheCorrupt:
            .cacheCorrupt(processesStarted: processesStarted)
        case .contentChanged:
            .contentChanged(processesStarted: processesStarted)
        default:
            .cacheFailure(processesStarted: processesStarted, reason: String(describing: error))
        }
    }

    private static func digest(_ fields: [String]) -> String {
        var data = Data()
        for field in fields {
            var length = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(contentsOf: field.utf8)
        }
        return sha256(data)
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (48 ... 57).contains($0) || (97 ... 102).contains($0)
        }
    }

    public func readArtifact(
        handle: String,
        mode: ArtifactReadMode = .range(offset: 0, length: 65_536),
        byteBudget: Int = 65_536
    ) async throws -> ArtifactSlice {
        if handle.hasPrefix("run_") {
            if managedArtifacts == nil { managedArtifacts = try ManagedRunArtifactStore(runtimeStore: runtimeStore) }
            return try await managedArtifacts!.read(handle: handle, mode: mode, byteBudget: byteBudget)
        }
        return try await evidenceStore.read(handle: handle, mode: mode, byteBudget: byteBudget)
    }

    public func workspaceSnapshot(
        path: String? = nil,
        sinceCursor: String? = nil,
        entryLimit: Int = 500,
        contextBudget: Int = 16_384
    ) async throws -> WorkspaceSnapshot {
        try await workspaceRuntime.snapshot(
            path: path,
            sinceCursor: sinceCursor,
            entryLimit: entryLimit,
            contextBudget: contextBudget
        )
    }

    public func workspaceSnapshotV2(
        path: String? = nil,
        sinceCursor: String? = nil,
        entryLimit: Int = 500,
        contextBudget: Int = 16_384,
        gitDiffRequest: GitDiffContextRequest? = nil,
        projectProfileRequest: ProjectProfileProjectionRequest? = nil
    ) async throws -> WorkspaceSnapshotV2Result {
        try await contextCompiler.workspaceSnapshot(
            path: path,
            sinceCursor: sinceCursor,
            entryLimit: entryLimit,
            contextBudget: contextBudget,
            gitDiffRequest: gitDiffRequest,
            projectProfileRequest: projectProfileRequest
        )
    }

    public func readContext(
        targets: [String],
        byteBudget: Int = 65_536,
        continuation: String? = nil
    ) async throws -> ReadContextResult {
        try await contextCompiler.readContext(
            targets: targets,
            byteBudget: byteBudget,
            continuation: continuation
        )
    }

    public func searchContext(
        query: String,
        path: String? = nil,
        maxResults: Int = 50,
        byteBudget: Int = 65_536,
        continuation: String? = nil
    ) async throws -> SearchContextResult {
        try await contextCompiler.searchContext(
            query: query,
            path: path,
            maxResults: maxResults,
            byteBudget: byteBudget,
            continuation: continuation
        )
    }

    public func searchContextV2(
        request: SearchContextRequestV2? = nil,
        continuation: String? = nil
    ) async throws -> SearchContextResultV2 {
        try await contextCompiler.searchContextV2(request: request, continuation: continuation)
    }

    public func semanticSearchContext(
        request: SemanticSearchContextRequest
    ) async throws -> SearchContextResultV2 {
        try await semanticSearchContextService.search(request)
    }

    public func analyzeChangeImpact(_ request: ChangeImpactRequest) async throws -> ChangeImpactResult {
        try await changeImpactService.analyze(request)
    }

    /// recommend初回のcatalogはcallerから受けず、共有ProjectProfileServiceのfresh exact
    /// resolutionから構成する。continuationは共通opaque入口へ渡す。
    public func recommendChangeImpact(
        _ request: ChangeImpactRecommendationRequest
    ) async throws -> ChangeImpactRecommendationResult {
        guard request.continuation == nil,
              let impactRequest = request.impactRequest,
              let projectID = request.projectID,
              let profileDigest = request.profileDigest else {
            throw ChangeImpactError.invalidContinuationRequest
        }
        let exact = try await projectProfiles.resolveExactProfile(profileDigest: profileDigest)
        guard exact.profile.projectId == projectID else {
            throw ChangeImpactError.recommendationJoinFailed("project/profile identity mismatch")
        }
        let catalog = ProjectProfileCatalogResult(
            schemaVersion: "aishell.project-profile-catalog.v1",
            root: exact.catalogRoot,
            observedCursor: exact.observedCursor,
            profiles: [exact.profile],
            computedProfiles: 1,
            cachedProfiles: 0
        )
        return try await changeImpactService.recommend(.init(
            impactRequest: impactRequest,
            projectID: projectID,
            profileDigest: profileDigest,
            catalog: catalog,
            byteBudget: request.byteBudget
        ))
    }

    public func continueChangeImpact(
        continuation: String,
        byteBudget: Int? = nil
    ) async throws -> ChangeImpactContinuationResult {
        try await changeImpactService.continueImpact(
            continuation: continuation,
            byteBudget: byteBudget
        )
    }

    private func primaryDiagnostic(for execution: RetainedProcessExecution) async throws -> String? {
        let stderrSamples = try await artifactSamples(execution.stderrArtifact)
        let stdoutSamples = try await artifactSamples(execution.stdoutArtifact)
        let samples = stderrSamples + stdoutSamples
        for text in samples {
            if let diagnostic = diagnosticLine(in: text) { return diagnostic }
        }
        return samples.lazy.flatMap { $0.split(whereSeparator: { $0.isNewline }).map(String.init) }
            .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
    }

    private func artifactSamples(_ artifact: ArtifactMetadata) async throws -> [String] {
        guard artifact.sizeBytes > 0 else { return [] }
        let head = try await evidenceStore.read(
            handle: artifact.handle,
            mode: .range(offset: 0, length: 65_536),
            byteBudget: 65_536
        )
        var samples = head.text.map { [$0] } ?? []
        if artifact.sizeBytes > head.returnedBytes {
            let tail = try await evidenceStore.read(
                handle: artifact.handle,
                mode: .tail(lines: 500),
                byteBudget: 65_536
            )
            if let text = tail.text { samples.append(text) }
        }
        return samples
    }

    private func diagnosticLine(in text: String) -> String? {
        let lines = text.split(whereSeparator: { $0.isNewline }).map(String.init)
        return lines.first(where: {
            $0.localizedCaseInsensitiveContains("error:")
                || $0.localizedCaseInsensitiveContains("fatal error")
                || $0.localizedCaseInsensitiveContains("syntaxerror")
        })
    }
}

public struct RunCheckRelevantInputBinding: Sendable {
    public let digest: String?
    public let reobserveDigest: @Sendable () async throws -> String?

    public init(
        digest: String?,
        reobserveDigest: @escaping @Sendable () async throws -> String?
    ) {
        self.digest = digest
        self.reobserveDigest = reobserveDigest
    }
}

public struct RunCheckResolutionContext: Sendable {
    /// ProjectProfileServiceが同じworkspace observationから発行したcatalog。
    public let profileCatalog: ProjectProfileCatalogResult
    public let focusedAdmission: FocusedCheckService.Admission?
    /// callerが明示するoverride。profile descriptorが要求する未指定keyは現在process環境からexactに束縛する。
    public let environment: [String: String]
    /// checkごとにcallerが証明したcomplete relevant-input closure。欠損時はcache eligibleにしない。
    public let relevantInputsByCheckID: [String: RunCheckRelevantInputBinding]

    public init(
        profileCatalog: ProjectProfileCatalogResult,
        focusedAdmission: FocusedCheckService.Admission? = nil,
        environment: [String: String] = [:],
        relevantInputsByCheckID: [String: RunCheckRelevantInputBinding] = [:]
    ) {
        self.profileCatalog = profileCatalog
        self.focusedAdmission = focusedAdmission
        self.environment = environment
        self.relevantInputsByCheckID = relevantInputsByCheckID
    }
}

public struct RunCheckPipelineStepResult: Encodable, Sendable {
    public let stepID: String
    public let terminalState: CheckFreshnessCache.TerminalState
    public let sourceRunID: String
    public let stdoutArtifactSHA256: String
    public let stderrArtifactSHA256: String
    public let artifacts: [ArtifactMetadata]
    public let skippedBecauseDependencyFailed: Bool

    init(_ result: CheckFreshnessCache.Result) {
        stepID = result.stepID
        terminalState = result.terminalState
        sourceRunID = result.sourceRunID
        stdoutArtifactSHA256 = result.stdoutArtifactSHA256
        stderrArtifactSHA256 = result.stderrArtifactSHA256
        artifacts = result.artifacts
        skippedBecauseDependencyFailed = result.sourceRunID.hasPrefix("skipped_dependency:")
    }
}

public struct RunCheckPipelineResult: Encodable, Sendable {
    public let schemaVersion: String
    public let planDigest: String
    public let selectionDigest: String
    public let requestedCheckIDs: [String]
    public let plannedCheckIDs: [String]
    public let cacheState: CheckFreshnessCache.State
    public let processesStarted: Int
    public let publications: Int
    public let steps: [RunCheckPipelineStepResult]
    public let lookupEvidence: [CheckFreshnessCache.LookupEvidence]
    public let diagnostics: DiagnosticAdapterResult?
}

public enum RunCheckPipelineError: Swift.Error, Equatable, Sendable {
    case invocationInvalid(processesStarted: Int)
    case selectionStale(processesStarted: Int)
    case cacheMiss(processesStarted: Int, evidence: [CheckFreshnessCache.LookupEvidence])
    case cacheCorrupt(processesStarted: Int)
    case contentChanged(processesStarted: Int)
    case cacheFailure(processesStarted: Int, reason: String)
    case dispatchNotReady(processesStarted: Int)

    public var code: String {
        switch self {
        case .invocationInvalid: "RUN_CHECK_INVOCATION_INVALID"
        case .selectionStale: "RUN_CHECK_SELECTION_STALE"
        case .cacheMiss: "RUN_CHECK_CACHE_MISS"
        case .cacheCorrupt: "CACHE_CORRUPT"
        case .contentChanged: "CONTENT_CHANGED"
        case .cacheFailure: "RUN_CHECK_CACHE_FAILED"
        case .dispatchNotReady: "RUN_CHECK_START_NOT_READY"
        }
    }

    public var processesStarted: Int {
        switch self {
        case .invocationInvalid(let count), .selectionStale(let count),
             .cacheCorrupt(let count), .contentChanged(let count), .dispatchNotReady(let count): count
        case .cacheMiss(let count, _), .cacheFailure(let count, _): count
        }
    }
}

private final class RunCheckProcessCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
