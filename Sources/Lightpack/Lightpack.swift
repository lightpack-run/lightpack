import Foundation
import llama
import Metal

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public let lightpackVersion = "0.0.6"

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public class Lightpack: LightpackProtocol, ObservableObject {
    @Published public private(set) var models: [String: LPModel] = [:]
    @Published public private(set) var families: [String: LPModelFamily] = [:]
    @Published public private(set) var loadedModel: LPModel?
    @Published public private(set) var totalModelSize: Double = 0.0
    @Published private(set) var isInitialized: Bool = false
    
    public var isDownloading: Bool {
        models.values.contains { $0.status == .downloading }
    }
    
    private let apiKey: String
    
    private let baseURL = "https://lightpack.run/api/v1"
    private let userDefaultsModelMetadataKey = "LPModelMetadata"
    private let urlSession: URLSessionProtocol = URLSession.shared
    private let clientInfo: LPClientInfo

    private var enableLogging: Bool = true
    private func log(_ message: String, _ error: Bool = false) {
        if enableLogging { print("[Lightpack] \(message)") }
        if error == true { sendApiEvent(.packageError, data: ["error": message]) }
    }
    
    private var chatManager: ChatManager
    private var downloadManager: DownloadManager
    private let eventQueue = LPEventQueue()
    
//  qwen2-1_5b-instruct-q8_0
    private let defaultModelId = "23a77013-fe73-4f26-9ab2-33d315a71924"
    
    public init(apiKey: String, enableLogging: Bool = true) {
        self.apiKey = apiKey
        self.enableLogging = enableLogging
        
        LPNetworkMonitor.shared.startMonitoring()
        self.clientInfo = Lightpack.getClientInfo()
        self.chatManager = ChatManager(enableLogging: enableLogging)
        self.downloadManager = DownloadManager(enableLogging: enableLogging)
       
        Task {
            await loadModelMetadata()
            DispatchQueue.main.async {
                self.isInitialized = true
                self.log("Lightpack initialization completed")
            }
        }
    }
    
    private func awaitInitialization() async {
        // 100 milliseconds
        while !isInitialized { try? await Task.sleep(nanoseconds: 100 * 1_000_000) }
    }
    
    private func loadModelMetadata() async {
        guard let modelMetadata = await loadModelMetadataFromUserDefaults() else { return }
        
        do {
            let applicationSupportDirectoryURL = try getApplicationSupportDirectoryURL()
            await updateModelsAndFamilies(with: modelMetadata, applicationSupportDirectoryURL: applicationSupportDirectoryURL)
        } catch {
            log("Error accessing application support directory: \(error)", true)
        }
    }

    private func loadModelMetadataFromUserDefaults() async -> LPModelMetadataResponse? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsModelMetadataKey) else {
            log("No model metadata found in UserDefaults")
            return nil
        }
        
        do {
            let modelMetadata = try JSONDecoder().decode(LPModelMetadataResponse.self, from: data)
            guard !modelMetadata.models.isEmpty else {
                log("Decoded model metadata is empty")
                return nil
            }
            return modelMetadata
        } catch {
            log("Error decoding model data: \(error)", true)
            return nil
        }
    }

    private func updateModelsAndFamilies(with metadata: LPModelMetadataResponse, applicationSupportDirectoryURL: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            for (modelId, model) in metadata.models {
                var updatedModel = model
                let fileURL = applicationSupportDirectoryURL.appendingPathComponent(modelId)
                updatedModel.status = FileManager.default.fileExists(atPath: fileURL.path) ? .downloaded : .notDownloaded
                self.models[modelId] = updatedModel
            }
            self.families = metadata.familyModels
            self.updateTotalModelSize()
            self.saveModelMetadata()
        }
    }

    private func saveAndMergeModelMetadata(models: [LPModel]? = nil, families: [LPModelFamily]? = nil) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let existingMetadata = self.loadExistingMetadata()
            
            var updatedModels = self.models
            var updatedFamilies = existingMetadata?.familyModels ?? [:]
            var didUpdate = false
            
            if let newModels = models, !newModels.isEmpty {
                updatedModels = self.mergeModels(newModels: newModels, existingModels: self.models)
                didUpdate = true
            }
            
            if let newFamilies = families, !newFamilies.isEmpty {
                updatedFamilies = self.mergeFamilies(newFamilies: newFamilies, existingFamilies: existingMetadata?.familyModels ?? [:])
                didUpdate = true
            }
            
            if didUpdate {
                let newMetadata = LPModelMetadataResponse(
                    familyModels: updatedFamilies,
                    models: updatedModels,
                    updatedAt: ISO8601DateFormatter().string(from: Date())
                )
                
                self.saveMetadataToUserDefaults(newMetadata)
                self.updateCurrentModelsAndFamilies(models: updatedModels, families: updatedFamilies)
                self.log("Updated metadata saved")
            }
        }
    }

    private func loadExistingMetadata() -> LPModelMetadataResponse? {
        guard let data = UserDefaults.standard.data(forKey: userDefaultsModelMetadataKey),
              let metadata = try? JSONDecoder().decode(LPModelMetadataResponse.self, from: data) else {
            log("No metadata found in UserDefaults on app start")
            return nil
        }
        return metadata
    }

    private func mergeModels(newModels: [LPModel]?, existingModels: [String: LPModel]) -> [String: LPModel] {
        var mergedModels = existingModels
        guard let newModels = newModels else { return mergedModels }
        
        for newModel in newModels {
            if let existingModel = mergedModels[newModel.modelId] {
                var updatedModel = newModel
                updatedModel.status = existingModel.status
                updatedModel.downloadProgress = existingModel.downloadProgress
                updatedModel.status = isModelOutdated(existingModel, newModel) ? .outdated : updatedModel.status
                mergedModels[newModel.modelId] = updatedModel
            } else {
                mergedModels[newModel.modelId] = newModel
            }
        }
        return mergedModels
    }

    private func mergeFamilies(newFamilies: [LPModelFamily]?, existingFamilies: [String: LPModelFamily]) -> [String: LPModelFamily] {
        var mergedFamilies = existingFamilies
        guard let newFamilies = newFamilies else { return mergedFamilies }
        
        log("Merging new families...")
        for family in newFamilies {
            mergedFamilies[family.familyId] = family
            log("Added or updated family \(family.familyId): \(family)")
        }
        return mergedFamilies
    }

    private func saveMetadataToUserDefaults(_ metadata: LPModelMetadataResponse) {
        let encoder = JSONEncoder()
        if let encodedData = try? encoder.encode(metadata) {
            UserDefaults.standard.set(encodedData, forKey: userDefaultsModelMetadataKey)
            log("Saved metadata to UserDefaults")
        } else {
            log("Failed to encode new metadata")
        }
    }

    private func updateCurrentModelsAndFamilies(models: [String: LPModel], families: [String: LPModelFamily]) {
        DispatchQueue.main.async { [weak self] in
            self?.models = models
            self?.families = families
            self?.log("Updated models and families")
        }
    }
    
    private func checkNetworkConnectivity() throws {
        guard LPNetworkMonitor.shared.isConnected else {
            throw LPError.networkError(NSError(domain: "No network connection", code: 0, userInfo: nil))
        }
    }
    
    private func getModel(alias: String?, modelId: String?) async throws -> LPModel {
        await awaitInitialization()

        func updateModelStatus(_ model: inout LPModel, fileExists: Bool) {
            if fileExists && model.status != .downloaded {
                model.status = .downloaded
                log("Updated model status to downloaded based on file existence")
            } else if !fileExists && model.status == .downloaded {
                model.status = .notDownloaded
                log("Updated model status to not downloaded based on file absence")
            }
        }

        // Check modelId first
        if let modelId = modelId, !modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log("Checking model with ID: \(modelId)")
            if var model = await getModelFromStore(id: modelId) {
                let fileExists = modelFileExists(for: modelId)
                updateModelStatus(&model, fileExists: fileExists)
                await updateModelInStore(model)
                return model
            }
        }

        // If modelId not found or invalid, check alias
        if let alias = alias, !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            log("Checking model with alias: \(alias)")
            if var model = await getModelByAlias(alias) {
                let fileExists = modelFileExists(for: model.modelId)
                updateModelStatus(&model, fileExists: fileExists)
                await updateModelInStore(model)
                return model
            }
        }

        // If model not found locally, check network
        try checkNetworkConnectivity()
        log("Model not found locally. Checking network...")

        return try await withCheckedThrowingContinuation { continuation in
            let idToCheck = modelId ?? alias ?? ""
            getModels(modelIds: [idToCheck]) { [weak self] result in
                guard let self = self else { return }
                
                // Ensure we are on the main thread when updating UI and `@Published` properties
                Task { @MainActor in
                    switch result {
                    case .success((let response, _)):
                        if let model = response.models.first {
                            // Ensure that `updateModelInStore` is running on the main thread
                            await self.updateModelInStore(model)
                            self.log("Model found on network: \(model.modelId)")
                            continuation.resume(returning: model)
                        } else {
                            self.log("Model not found in Lightpack. Please try another model")
                            continuation.resume(throwing: LPError.modelNotFound)
                        }
                    case .failure(let error):
                        self.log("Network request failed: \(error.localizedDescription)")
                        continuation.resume(throwing: LPError.networkError(error))
                    }
                }
            }
        }
    }

    private func getModelFromStore(id: String) async -> LPModel? {
        await MainActor.run { models[id] }
    }

    private func getModelByAlias(_ alias: String) async -> LPModel? {
        await MainActor.run {
            models.values.first { $0.alias == alias }
        }
    }

    @MainActor
    private func updateModelInStore(_ model: LPModel) {
        models[model.modelId] = model
        saveModelMetadata()
    }

    private func getAndValidateModel(alias: String?, modelId: String?) async throws -> LPModel {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelId = modelId?.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let validInput = trimmedAlias.flatMap({ $0.isEmpty ? nil : $0 }) ??
                               trimmedModelId.flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw LPError.modelIsEmpty
        }
        
        // If we reach here, at least one of alias or modelId is non-empty
        if !validInput.isEmpty {
            return try await getModel(alias: trimmedAlias, modelId: trimmedModelId)
        } else {
            throw LPError.modelIsEmpty
        }
    }

    @MainActor
    public func loadModel(alias: String? = nil, modelId: String? = nil) async throws {
        await awaitInitialization()
        log("Loading model (alias: \(alias ?? "nil"), modelId: \(modelId ?? "nil"))")

        let model = try await getAndValidateModel(alias: alias, modelId: modelId)

        if model.status == .notDownloaded || model.status == .paused {
            try await downloadModel(alias: alias, modelId: modelId)
        }

        if model.modelId != loadedModel?.modelId {
            try await loadModelIntoContext(model)
        }
    }

    @MainActor
    public func downloadModel(alias: String? = nil, modelId: String? = nil) async throws {
        await awaitInitialization()
        log("Download model (alias: \(alias ?? "nil"), modelId: \(modelId ?? "nil"))")

        let model = try await getAndValidateModel(alias: alias, modelId: modelId)

        guard model.status != .downloaded else {
            log("Model \(model.modelId) is already downloaded. Skipping download process.")
            return
        }

        guard !downloadManager.isDownloadInProgress(for: model.modelId) else {
            log("Download for model \(model.modelId) is already in progress.")
            return
        }

        try await performModelDownload(model)
    }

    @MainActor
    public func pauseDownloadingModel(alias: String? = nil, modelId: String? = nil) async throws {
        await awaitInitialization()
        log("Pause download model (alias: \(alias ?? "nil"), modelId: \(modelId ?? "nil"))")

        let model = try await getAndValidateModel(alias: alias, modelId: modelId)
        let success = try await downloadManager.pauseDownload(model)

        updateModelAfterPause(model.modelId, success: success)
        sendApiEvent(.pauseDownloadingModel, data: ["modelId": model.modelId])
    }

    @MainActor
    public func resumeDownloadingModel(alias: String? = nil, modelId: String? = nil) async throws {
        await awaitInitialization()
        log("Resume download model (alias: \(alias ?? "nil"), modelId: \(modelId ?? "nil"))")

        try checkNetworkConnectivity()
        let model = try await getAndValidateModel(alias: alias, modelId: modelId)

        guard let downloadUrl = model.downloadUrl else {
            throw LPError.downloadError(.noDownloadUrl)
        }

        try await resumeModelDownload(model, downloadUrl: downloadUrl)
        
        sendApiEvent(.resumeDownloadingModel, data: ["modelId": model.modelId])
    }

    @MainActor
    public func cancelDownloadingModel(alias: String? = nil, modelId: String? = nil) async throws {
        await awaitInitialization()
        log("Cancel download model (alias: \(alias ?? "nil"), modelId: \(modelId ?? "nil"))")

        let model = try await getAndValidateModel(alias: alias, modelId: modelId)
        downloadManager.cancelDownload(model)

        updateModelStatus(modelId: model.modelId, newStatus: .notDownloaded)
        updateModelProgress(modelId: model.modelId, progress: 0)
        objectWillChange.send()

        sendApiEvent(.cancelDownloadingModel, data: ["modelId": model.modelId])
    }

    @MainActor
    public func removeModels(aliases: [String]? = nil, modelIds: [String]? = nil, removeAll: Bool = false) async throws {
        await awaitInitialization()
        log("Removing models: (aliases: \(aliases ?? []), modelIds: \(modelIds ?? [])), removeAll: \(removeAll)")

        if removeAll {
            try await performModelRemoval(modelIds: nil, removeAll: true)
        } else {
            var modelsToRemove = Set<String>()

            if let modelIds = modelIds {
                modelsToRemove.formUnion(modelIds)
            }

            if let aliases = aliases {
                let aliasModelIds = models.values
                    .filter { aliases.contains($0.alias) }
                    .map { $0.modelId }
                modelsToRemove.formUnion(aliasModelIds)
            }

            if !modelsToRemove.isEmpty {
                try await performModelRemoval(modelIds: Array(modelsToRemove), removeAll: false)
            } else {
                log("No models to remove")
            }
        }
    }

    @MainActor
    public func chatModel(alias: String? = nil, modelId: String? = nil, messages: [LPChatMessage], onToken: @escaping (String) -> Void) async throws {
        await awaitInitialization()

        let model = try await getAndValidateModel(alias: alias, modelId: modelId)
        log("Chat model \(model.modelId)")

        try await loadModel(alias: alias, modelId: modelId)
        try await chatManager.complete(messages: messages, model: model, onToken: onToken)

        sendApiEvent(.chatModel, data: ["modelId": model.modelId])
    }
    
    public func clearChat() async {
        log("Context cleared")
        await awaitInitialization()
        await chatManager.clear()
        sendApiEvent(.clearChat)
    }
    
    private func getModelDownloadUrl(modelId: String) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            getModelDownload(modelId: modelId) { result in
                switch result {
                case .success(let response):
                    continuation.resume(returning: response.downloadUrl)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    private func updateModelDownloadUrl(modelId: String, downloadUrl: String) {
        if var model = models[modelId] {
            model.downloadUrl = downloadUrl
            models[modelId] = model
        }
    }
    
    private func getFileURL(_ modelId: String) -> URL {
        do {
            let applicationSupportDirectoryURL = try getApplicationSupportDirectoryURL()
            return applicationSupportDirectoryURL.appendingPathComponent(modelId)
        } catch {
            log("Error getting file URL: \(error.localizedDescription)", true)
            return URL(fileURLWithPath: "") // Return an empty URL or handle the error as needed
        }
    }
    
    private func getApplicationSupportDirectoryURL() throws -> URL {
        let fileManager = FileManager.default
        return try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    private func enumerateFiles(at directoryURL: URL) throws -> [URL] {
        let fileManager = FileManager.default
        return try fileManager.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
    }

    private func removeFiles(at directoryURL: URL, modelIds: [String]) throws {
        let fileManager = FileManager.default
        for modelId in modelIds {
            let fileURL = directoryURL.appendingPathComponent(modelId)
            if fileManager.fileExists(atPath: fileURL.path) {
                try fileManager.removeItem(at: fileURL)
            }
        }
    }
    
    private func modelFileExists(for modelId: String) -> Bool {
        do {
            let applicationSupportDirectoryURL = try getApplicationSupportDirectoryURL()
            let fileURL = applicationSupportDirectoryURL.appendingPathComponent(modelId)
            return FileManager.default.fileExists(atPath: fileURL.path)
        } catch {
            return false
        }
//        let fileManager = FileManager.default
//        let modelFilePath = getFileURL(modelId).path
//        return fileManager.fileExists(atPath: modelFilePath)
    }
    
    private func updateModelStatus(modelId: String, newStatus: LPModelStatus) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if var model = self.models[modelId] {
                model.status = newStatus
                self.models[modelId] = model
                self.log("Update model status \(modelId) to \(newStatus)")
                self.saveModelMetadata()
            } else {
                self.log("Model \(modelId) not found for status update")
            }
        }
    }
    
    private func updateModelStatusIfNeeded(for modelId: String, with model: inout LPModel) {
        let fileExists = modelFileExists(for: modelId)
        if fileExists {
            if model.status != .downloaded {
                updateModelStatus(modelId: modelId, newStatus: .downloaded)
                model.status = .downloaded
                log("Updated model status to downloaded based on file existence")
            }
        } else if model.status == .downloaded {
            updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
            model.status = .notDownloaded
            log("Updated model status to not downloaded based on file absence")
        }
    }

    private func saveModelMetadata() {
        let encoder = JSONEncoder()
        if let encodedData = try? encoder.encode(LPModelMetadataResponse(familyModels: families, models: models, updatedAt: ISO8601DateFormatter().string(from: Date()))) {
            UserDefaults.standard.set(encodedData, forKey: userDefaultsModelMetadataKey)
        } else {
            log("Failed to encode model metadata")
        }
    }

    private func updateModelProgress(modelId: String, progress: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if var model = self.models[modelId] {
                model.downloadProgress = progress
                self.models[modelId] = model
                if progress >= 1.0 {
                    self.updateModelStatus(modelId: modelId, newStatus: .downloaded)
                    log("Downloaded!")
                } else {
                    let percentage = min(floor(progress * 1000) / 10, 99.9)
                    log("Download progress: \(String(format: "%.1f", percentage))%")
                }
            }
        }
    }
    
    private func updateTotalModelSize() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.totalModelSize = self.models.values
                .filter { $0.status == .downloaded }
                .map { Double($0.size) }
                .reduce(0.0, +)
        }
    }
    
    private func isModelOutdated(_ localModel: LPModel, _ remoteModel: LPModel) -> Bool {
        guard let localDate = ISO8601DateFormatter().date(from: localModel.updatedAt),
              let remoteDate = ISO8601DateFormatter().date(from: remoteModel.updatedAt) else {
            return false // If we can't parse the dates, assume the model is not outdated
        }
        return remoteDate > localDate
    }
    
    // MARK: - Private Helper Methods

    private func loadModelIntoContext(_ model: LPModel) async throws {
        let startTime = DispatchTime.now()
        let modelUrl = getFileURL(model.modelId)
        let context = try LlamaContext.create_context(path: modelUrl.path)
        chatManager.setContext(context)
        
        DispatchQueue.main.async { self.loadedModel = model }
        
        let loadTime = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000.0
        let backend = await context.getBackendInfo()
        
        log("\(model.title) loaded in \(String(format: "%.2f", loadTime))s from \(backend)")
        sendApiEvent(.loadModel, data: ["modelId": model.modelId])
    }

    private func performModelDownload(_ model: LPModel) async throws {
        updateModelStatus(modelId: model.modelId, newStatus: .downloading)
        updateModelProgress(modelId: model.modelId, progress: downloadManager.getProgress(for: model.modelId))

        let downloadUrl = try await getOrFetchDownloadUrl(for: model)
        let downloadedUrl = try await downloadManager.downloadModel(model, downloadUrl: downloadUrl) { [weak self] modelId, progress in
            self?.updateModelProgress(modelId: modelId, progress: progress)
        }

        if FileManager.default.fileExists(atPath: downloadedUrl.path) {
            updateModelStatus(modelId: model.modelId, newStatus: .downloaded)
            updateTotalModelSize()
            sendApiEvent(.downloadModel, data: ["modelId": model.modelId])
        } else {
            throw LPError.downloadError(.fileMissing)
        }
    }

    private func getOrFetchDownloadUrl(for model: LPModel) async throws -> String {
        if let downloadUrl = model.downloadUrl {
            return downloadUrl
        }
        let downloadUrl = try await getModelDownloadUrl(modelId: model.modelId)
        updateModelDownloadUrl(modelId: model.modelId, downloadUrl: downloadUrl)
        return downloadUrl
    }

    private func updateModelAfterPause(_ modelId: String, success: Bool) {
        if success {
            let progress = downloadManager.getProgress(for: modelId)
            updateModelStatus(modelId: modelId, newStatus: .paused)
            updateModelProgress(modelId: modelId, progress: progress)
        } else {
            log("Failed to pause download for model: \(modelId)")
            updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
        }
    }

    private func resumeModelDownload(_ model: LPModel, downloadUrl: String) async throws {
        updateModelStatus(modelId: model.modelId, newStatus: .downloading)
        
        let success = try await downloadManager.resumeDownload(model, downloadUrl: downloadUrl) { [weak self] modelId, progress in
            self?.updateModelProgress(modelId: modelId, progress: progress)
        }
        
        if success {
            updateModelStatus(modelId: model.modelId, newStatus: .downloading)
            updateTotalModelSize()
        } else {
            log("Failed to resume download for model: \(model.modelId)")
            updateModelStatus(modelId: model.modelId, newStatus: .paused)
        }
    }

    private func performModelRemoval(modelIds: [String]?, removeAll: Bool) async throws {
        let applicationSupportDirectory = try getApplicationSupportDirectoryURL()
        
        guard removeAll || (modelIds != nil && !modelIds!.isEmpty) else {
            log("No models to remove")
            return
        }
        
        var removedModelIds: [String] = []
        
        if removeAll {
            removedModelIds = try await removeAllModels(at: applicationSupportDirectory)
        } else if let modelIds = modelIds {
            try removeFiles(at: applicationSupportDirectory, modelIds: modelIds)
            removedModelIds = modelIds
            for modelId in modelIds {
                updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
            }
        }
        
        updateTotalModelSize()
        
        if removeAll { chatManager.clearContext() }
        
        sendRemoveModelsEvent(removedModelIds: removedModelIds, removeAll: removeAll)
    }

    private func removeAllModels(at directory: URL) async throws -> [String] {
        let fileURLs = try enumerateFiles(at: directory)
        var removedModelIds: [String] = []
        
        for fileURL in fileURLs {
            try FileManager.default.removeItem(at: fileURL)
            let modelId = fileURL.lastPathComponent
            updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
            removedModelIds.append(modelId)
        }
        
        for modelId in models.keys {
            updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
        }
        
        return removedModelIds
    }

    private func sendRemoveModelsEvent(removedModelIds: [String], removeAll: Bool) {
        Task(priority: .background) {
            var data: [String: Any] = [:]
            if !removedModelIds.isEmpty {
                data["modelIds"] = removedModelIds.joined(separator: ",")
            }
            if removeAll { data["removeAll"] = removeAll }
            self.sendApiEvent(.removeModels, data: data)
        }
    }
    
    private func checkForUpdates(remoteModels: [LPModel]) -> [String] {
        var updatedModels: [String] = []
        for remoteModel in remoteModels {
            if let localModel = self.models[remoteModel.modelId],
               localModel.status == .downloaded,
               isModelOutdated(localModel, remoteModel) {
                updateModelStatus(modelId: remoteModel.modelId, newStatus: .outdated)
                updatedModels.append(remoteModel.modelId)
            }
        }
        return updatedModels
    }
    
    private func checkForFamilyUpdates(remoteFamilies: [LPModelFamily]) -> [String] {
        var updatedFamilies: [String] = []
        for remoteFamily in remoteFamilies {
            if let localFamily = self.families[remoteFamily.familyId],
               isFamilyOutdated(localFamily, remoteFamily) {
                updatedFamilies.append(remoteFamily.familyId)
            }
        }
        return updatedFamilies
    }

    private func isFamilyOutdated(_ localFamily: LPModelFamily, _ remoteFamily: LPModelFamily) -> Bool {
        guard let localDate = ISO8601DateFormatter().date(from: localFamily.updatedAt),
              let remoteDate = ISO8601DateFormatter().date(from: remoteFamily.updatedAt) else {
            return false // If we can't parse the dates, assume the family is not outdated
        }
        return remoteDate > localDate
    }
    
    private func cleanModelId(_ modelId: String?) -> String {
        return modelId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? modelId!.trimmingCharacters(in: .whitespacesAndNewlines)
            : loadedModel?.modelId ?? defaultModelId
    }
    
    private func cleanAndJoinArray(_ array: [String]?) -> String? {
        guard let array = array else { return nil }
        let cleaned = array.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
    }
    
    public func getModels(
        aliases: [String]? = nil,
        bitMax: Int? = nil,
        bitMin: Int? = nil,
        familyIds: [String]? = nil,
        modelIds: [String]? = nil,
        page: Int? = nil,
        pageSize: Int? = nil,
        parameterIds: [String]? = nil,
        quantizationIds: [String]? = nil,
        sizeMax: Float? = nil,
        sizeMin: Float? = nil,
        sort: String? = nil,
        completion: @escaping (Result<(LPModelsResponse, [String]), LPError>) -> Void
    ) {
        var parameters: [String: String] = [:]
        var validationMessages: [String] = []

        // Validate and add numeric parameters
        if let bitMax = bitMax {
            if bitMax > 0 {
                parameters["bitMax"] = String(bitMax)
            } else {
                validationMessages.append("bitMax must be greater than 0")
            }
        }
        if let bitMin = bitMin {
            if bitMin > 0 {
                parameters["bitMin"] = String(bitMin)
            } else {
                validationMessages.append("bitMin must be greater than 0")
            }
        }
        if let page = page {
            if page > 0 {
                parameters["page"] = String(page)
            } else {
                validationMessages.append("page must be greater than 0")
            }
        }
        if let pageSize = pageSize {
            if pageSize > 0 && pageSize <= 100 {
                parameters["pageSize"] = String(pageSize)
            } else {
                validationMessages.append("pageSize must be between 1 and 100")
            }
        }
        if let sizeMax = sizeMax {
            if sizeMax > 0 {
                parameters["sizeMax"] = String(sizeMax)
            } else {
                validationMessages.append("sizeMax must be greater than 0")
            }
        }
        if let sizeMin = sizeMin {
            if sizeMin > 0 {
                parameters["sizeMin"] = String(sizeMin)
            } else {
                validationMessages.append("sizeMin must be greater than 0")
            }
        }

        // Clean and add array parameters
        if let aliases = cleanAndJoinArray(aliases) { parameters["aliases"] = aliases }
        if let familyIds = cleanAndJoinArray(familyIds) { parameters["familyIds"] = familyIds }
        if let modelIds = cleanAndJoinArray(modelIds) { parameters["modelIds"] = modelIds }
        if let parameterIds = cleanAndJoinArray(parameterIds) { parameters["parameterIds"] = parameterIds }
        if let quantizationIds = cleanAndJoinArray(quantizationIds) { parameters["quantizationIds"] = quantizationIds }

        // Validate and add sort parameter
        if let sort = sort?.trimmingCharacters(in: .whitespacesAndNewlines), !sort.isEmpty {
            let sortComponents = sort.split(separator: ":")
            if sortComponents.count == 2 && ["asc", "desc"].contains(sortComponents[1]) {
                parameters["sort"] = sort
            } else {
                validationMessages.append("Invalid sort format. Should be 'field:asc' or 'field:desc'")
            }
        }

        // Log validation messages and return early if there are issues
        if !validationMessages.isEmpty {
            let logMessage = "getModels validation issues: " + validationMessages.joined(separator: ", ")
            log(logMessage)
            completion(.failure(LPError.validationError(message: logMessage)))
            return
        }

        performRequest(parameters: parameters, apiType: .getModels) { [weak self] (result: Result<LPModelsResponse, LPError>) in
            switch result {
            case .success(let response):
                let updatedModels = self?.checkForUpdates(remoteModels: response.models) ?? []
                self?.saveAndMergeModelMetadata(models: response.models, families: nil)
                completion(.success((response, updatedModels)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    public func getModelFamilies(
        aliases: [String]? = nil,
        authors: [String]? = nil,
        familyIds: [String]? = nil,
        modelParameterIds: [String]? = nil,
        page: Int? = nil,
        pageSize: Int? = nil,
        sort: String? = nil,
        titles: [String]? = nil,
        updatedAfter: String? = nil,
        updatedBefore: String? = nil,
        completion: @escaping (Result<(LPModelFamiliesResponse, [String]), LPError>) -> Void
    ) {
        var parameters: [String: String] = [:]
        var validationMessages: [String] = []

        // Clean and add array parameters
        if let aliases = cleanAndJoinArray(aliases) { parameters["aliases"] = aliases }
        if let authors = cleanAndJoinArray(authors) { parameters["authors"] = authors }
        if let familyIds = cleanAndJoinArray(familyIds) { parameters["familyIds"] = familyIds }
        if let modelParameterIds = cleanAndJoinArray(modelParameterIds) { parameters["modelParameterIds"] = modelParameterIds }
        if let titles = cleanAndJoinArray(titles) { parameters["titles"] = titles }

        // Validate and add numeric parameters
        if let page = page {
            if page > 0 {
                parameters["page"] = String(page)
            } else {
                validationMessages.append("page must be greater than 0")
            }
        }
        if let pageSize = pageSize {
            if pageSize > 0 && pageSize <= 100 {
                parameters["pageSize"] = String(pageSize)
            } else {
                validationMessages.append("pageSize must be between 1 and 100")
            }
        }

        // Validate and add sort parameter
        if let sort = sort?.trimmingCharacters(in: .whitespacesAndNewlines), !sort.isEmpty {
            let sortComponents = sort.split(separator: ":")
            if sortComponents.count == 2 && ["asc", "desc"].contains(sortComponents[1]) {
                parameters["sort"] = sort
            } else {
                validationMessages.append("Invalid sort format. Should be 'field:asc' or 'field:desc'")
            }
        }

        // Validate and add date parameters
        let dateFormatter = ISO8601DateFormatter()
        if let updatedAfter = updatedAfter {
            if dateFormatter.date(from: updatedAfter) != nil {
                parameters["updatedAfter"] = updatedAfter
            } else {
                validationMessages.append("updatedAfter must be a valid ISO8601 date string")
            }
        }
        if let updatedBefore = updatedBefore {
            if dateFormatter.date(from: updatedBefore) != nil {
                parameters["updatedBefore"] = updatedBefore
            } else {
                validationMessages.append("updatedBefore must be a valid ISO8601 date string")
            }
        }

        // Log validation messages and return early if there are issues
        if !validationMessages.isEmpty {
            let logMessage = "getModelFamilies validation issues: " + validationMessages.joined(separator: ", ")
            log(logMessage)
            DispatchQueue.main.async {
                completion(.failure(LPError.validationError(message: logMessage)))
            }
            return
        }

        performRequest(parameters: parameters, apiType: .getModelFamilies) { [weak self] (result: Result<LPModelFamiliesResponse, LPError>) in
            DispatchQueue.main.async {
                guard let self = self else {
                    completion(.failure(LPError.unknownError("Self is nil")))
                    return
                }
                
                switch result {
                case .success(let response):
                    let updatedFamilies = self.checkForFamilyUpdates(remoteFamilies: response.modelFamilies)
                    self.saveAndMergeModelMetadata(models: nil, families: response.modelFamilies)
                    completion(.success((response, updatedFamilies)))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
    
    private func getModelDownload(
        alias: String? = nil,
        modelId: String? = nil,
        completion: @escaping (Result<LPModelDownloadResponse, LPError>) -> Void
    ) {
        guard let alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines), !alias.isEmpty else {
            guard let modelId = modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !modelId.isEmpty else {
                completion(.failure(.invalidInput("Either alias or modelId is required and cannot be empty")))
                return
            }
            let parameters = ["modelId": modelId]
            performRequest(parameters: parameters, apiType: .getModelDownload, completion: completion)
            return
        }
        
        let parameters = ["alias": alias]
        performRequest(parameters: parameters, apiType: .getModelDownload, completion: completion)
    }
    
    private func sendApiEvent(_ eventType: LPApiType, data: [String: Any] = [:]) {
        let queuedEvent = LPQueuedEvent(type: eventType, data: data, timestamp: Date())
        eventQueue.enqueue(event: queuedEvent)
        Task(priority: .background) { if LPNetworkMonitor.shared.isConnected { await sendQueuedEvents() } }
    }
    
    private func sendQueuedEvents() async {
        let events = eventQueue.dequeueAll()
        for event in events {
            do {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    postEvent(eventType: LPApiType(rawValue: event.type) ?? .postEvent, data: event.data) { result in
                        switch result {
                        case .success(_):
                            continuation.resume()
                        case .failure(let error):
                            self.log("Failed to send event: \(error)")
                            continuation.resume(throwing: error)
                        }
                    }
                }
            } catch {
                // Error is already logged in the continuation
                // If an event fails to send, we might want to re-queue it or handle the failure
                eventQueue.enqueue(event: event)
            }
        }
    }

    private func postEvent(
        eventType: LPApiType,
        data: [String: Any],
        completion: @escaping (Result<LPPostEventResponse, LPError>) -> Void
    ) {
        var body: [String: Any] = ["type": eventType.rawValue]
        
        // Validate and clean the data
        let cleanedData = data.compactMapValues { value -> Any? in
            if let stringValue = value as? String {
                let trimmed = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } else if let arrayValue = value as? [String] {
                let cleaned = arrayValue.compactMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                return cleaned.isEmpty ? nil : cleaned.joined(separator: ",")
            }
            return value
        }
        
        body.merge(cleanedData) { (_, new) in new }
        
        performRequest(body: body, apiType: .postEvent, completion: completion)
    }
    
    private func performRequest<T: Codable>(
        parameters: [String: String] = [:],
        body: [String: Any]? = nil,
        apiType: LPApiType,
        completion: @escaping (Result<T, LPError>) -> Void
    ) {
        let endpoint: String?
        var method: String = "GET"

        switch apiType {
        case .postEvent:
            endpoint = "event"
            method = "POST"
        case .getModels:
            endpoint = "models"
        case .getModelDownload:
            endpoint = "model-download"
        case .getModelFamilies:
            endpoint = "model-families"
        default:
            endpoint = nil
        }

        guard let endpoint = endpoint else {
            completion(.failure(.endpointConstruction))
            return
        }

        var components = URLComponents(string: "\(baseURL)/\(endpoint)")!
        if method == "GET" {
            components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(String(Int64(Date().timeIntervalSince1970 * 1000)), forHTTPHeaderField: "lp-timestamp")
        if let type = body?["type"] as? String {
            request.setValue(type, forHTTPHeaderField: "lp-api-type")
        } else {
            request.setValue(apiType.rawValue, forHTTPHeaderField: "lp-api-type")
        }
        
        // Set common headers
        if let appBuild = clientInfo.appBuild {
            request.setValue(appBuild, forHTTPHeaderField: "lp-app-build")
        }
        if let appBundleId = clientInfo.appBundleId {
            request.setValue(appBundleId, forHTTPHeaderField: "lp-app-bundle-id")
        }
        if let appVersion = clientInfo.appVersion {
            request.setValue(appVersion, forHTTPHeaderField: "lp-app-version")
        }
        if let deviceAvailableStorage = clientInfo.deviceAvailableStorage {
            request.setValue(String(deviceAvailableStorage), forHTTPHeaderField: "lp-device-available-storage")
        }
        request.setValue(clientInfo.deviceId, forHTTPHeaderField: "lp-device-id")
        request.setValue(clientInfo.deviceLocale, forHTTPHeaderField: "lp-device-locale")
        request.setValue(clientInfo.deviceModel, forHTTPHeaderField: "lp-device-model")
        request.setValue(clientInfo.deviceOS, forHTTPHeaderField: "lp-device-os")
        request.setValue(clientInfo.deviceOSVersion, forHTTPHeaderField: "lp-device-os-version")
        if let preferredLanguage = clientInfo.devicePreferredLanguage {
            request.setValue(preferredLanguage, forHTTPHeaderField: "lp-device-preferred-language")
        }
        request.setValue(clientInfo.deviceTimeZone, forHTTPHeaderField: "lp-device-time-zone")
        if let deviceTotalStorage = clientInfo.deviceTotalStorage {
            request.setValue(String(deviceTotalStorage), forHTTPHeaderField: "lp-device-total-storage")
        }
        if let body = body, let error = body["error"] as? String {
            request.setValue(error, forHTTPHeaderField: "lp-package-error")
        }
        request.setValue(clientInfo.packageVersion, forHTTPHeaderField: "lp-package-version")
        
        // Set body for POST requests
        if method == "POST" {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let body = body {
                do {
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)
                } catch {
                    completion(.failure(.encodingError(error)))
                    return
                }
            }
        }
        
        urlSession.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.networkError(error)))
                return
            }
        
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(.invalidResponse))
                return
            }
            
            guard let data = data else {
                completion(.failure(.noData))
                return
            }
            
            if httpResponse.statusCode != 200 {
                do {
                    let errorResponse = try JSONDecoder().decode(LPErrorResponse.self, from: data)
                    completion(.failure(.apiError(errorResponse.error)))
                } catch {
                    completion(.failure(.unknownError("Status code: \(httpResponse.statusCode)")))
                }
                return
            }
            
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let result = try decoder.decode(T.self, from: data)
                completion(.success(result))
            } catch {
                completion(.failure(.decodingError(error)))
            }
        }.resume()
    }
    
    private static func getClientInfo() -> LPClientInfo {
        var appBuild: String? { Bundle.main.infoDictionary?["CFBundleVersion"] as? String }
        var appBundleId: String? { Bundle.main.bundleIdentifier }
        var appVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
        
        var deviceId: String { getDeviceId() }
        var deviceLocale: String { Locale.current.identifier }
        var deviceOS: String {
#if os(iOS)
            return "iOS"
#elseif os(macOS)
            return "macOS"
#elseif os(tvOS)
            return "tvOS"
#elseif os(watchOS)
            return "watchOS"
#elseif os(visionOS)
            return "visionOS"
#else
            return "Unknown"
#endif
        }
        var deviceOSVersion: String {
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            return "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        }
        
        var packageVersion: String { lightpackVersion }
        
        let timeZone = TimeZone.current.identifier
        
        let deviceModel: String = {
            #if os(iOS)
            return UIDevice.current.model
            #elseif os(macOS)
            return getReadableMacModel()
            #else
            return "Unknown"
            #endif
        }()
        
        let preferredLanguage: String? = Locale.preferredLanguages.isEmpty ? nil : Locale.preferredLanguages.first
        
        let (totalStorage, availableStorage) = getDiskSpaceInfo()
        
        return LPClientInfo(
            appBuild: appBuild,
            appBundleId: appBundleId,
            appVersion: appVersion,
            deviceAvailableStorage: availableStorage,
            deviceId: deviceId,
            deviceLocale: deviceLocale,
            deviceModel: deviceModel,
            deviceOS: deviceOS,
            deviceOSVersion: deviceOSVersion,
            devicePreferredLanguage: preferredLanguage,
            deviceTimeZone: timeZone,
            deviceTotalStorage: totalStorage,
            packageVersion: packageVersion
        )
    }
    
    private static func getDiskSpaceInfo() -> (total: Int?, available: Int64?) {
        let fileURL = URL(fileURLWithPath: NSHomeDirectory() as String)
        do {
            let values = try fileURL.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            let total = values.volumeTotalCapacity
            let available = values.volumeAvailableCapacityForImportantUsage
            return (total, available)
        } catch {
            return (nil, nil)
        }
    }

    private static func getDeviceId() -> String {
        let defaults = UserDefaults.standard
        let deviceIdKey = "deviceId"
        
        if let storedId = defaults.string(forKey: deviceIdKey) {
            return storedId
        }
        
        let newId = generateDeviceId()
        defaults.set(newId, forKey: deviceIdKey)
        return newId
    }
    
    private static func generateDeviceId() -> String {
        #if os(macOS)
        return getMacAddress() ?? UUID().uuidString
        #else
        return UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        #endif
    }
    
    #if os(macOS)
    private static func getMacAddress() -> String? {
        let task = Process()
        task.launchPath = "/sbin/ifconfig"
        task.arguments = ["en0"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        task.launch()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let pattern = "ether\\s([0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2}:[0-9a-fA-F]{2})"
            if let range = output.range(of: pattern, options: .regularExpression) {
                return String(output[range].split(separator: " ")[1])
            }
        }
        return nil
    }
    #endif
    
    private static func getMacModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var machine = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &machine, &size, nil, 0)
        return String(cString: machine)
    }

    private static func getReadableMacModel() -> String {
        let model = getMacModel()
        
        let modelMap = [
            "MacBookPro": "MacBook Pro",
            "MacBookAir": "MacBook Air",
            "MacBook": "MacBook",
            "iMac": "iMac",
            "Macmini": "Mac Mini",
            "MacPro": "Mac Pro"
        ]
        
        for (identifier, readableName) in modelMap {
            if model.hasPrefix(identifier) { return readableName }
        }
        
        return model
    }
    
    private class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
        @Published var downloadTasks: [String: URLSessionDownloadTask] = [:]
        @Published var downloadingModels: Set<String> = []
        @Published var pausedDownloads: Set<String> = []
        
        private var enableLogging: Bool = true
        private func log(_ message: String) { if enableLogging { print("[Lightpack] \(message)") } }
        init(enableLogging: Bool = true) { self.enableLogging = enableLogging }
        
        func isDownloadInProgress(for modelId: String) -> Bool {
            return downloadingModels.contains(modelId) || pausedDownloads.contains(modelId)
        }
        
        var observations: [String: NSKeyValueObservation] = [:]
        var resumeData: [String: Data] = [:]
        var downloadProgress: [String: Double] = [:]
        
        private lazy var urlSession: URLSession = {
            let configuration = URLSessionConfiguration.default
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.urlCache = nil
            return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        }()
        
        private var completionHandlers: [String: (Result<URL, Error>) -> Void] = [:]
        
        @MainActor
        func downloadModel(_ model: LPModel, downloadUrl: String, updateModelProgress: @escaping (String, Double) -> Void) async throws -> URL {
            let startTime = DispatchTime.now()
            
            return try await withCheckedThrowingContinuation { continuation in
                startDownload(model, downloadUrl: downloadUrl, updateModelProgress: updateModelProgress) { result in
                    switch result {
                    case .success(let url):
                        let loadTime = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000.0
                        self.log("Model download completed in \(loadTime) seconds")
                        self.downloadingModels.remove(model.modelId)
                        self.pausedDownloads.remove(model.modelId)
                        continuation.resume(returning: url)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
        
        func startDownload(_ model: LPModel, downloadUrl: String, updateModelProgress: @escaping (String, Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
            guard let url = URL(string: downloadUrl) else {
                completion(.failure(NSError(domain: "Invalid URL", code: 0, userInfo: nil)))
                return
            }
            
            let task: URLSessionDownloadTask
            
            if let resumeData = resumeData[model.modelId] {
                task = urlSession.downloadTask(withResumeData: resumeData)
            } else {
                task = urlSession.downloadTask(with: url)
            }
            
            task.taskDescription = model.modelId
            
            downloadTasks[model.modelId] = task
            downloadingModels.insert(model.modelId)
            pausedDownloads.remove(model.modelId)
            
            observations[model.modelId] = task.progress.observe(\.fractionCompleted) { observedProgress, _ in
//                DispatchQueue.main.async {
                    self.downloadProgress[model.modelId] = observedProgress.fractionCompleted
                    updateModelProgress(model.modelId, observedProgress.fractionCompleted)
//                }
            }
            
            completionHandlers[model.modelId] = completion
            
            task.resume()
        }
        
        @MainActor
        func pauseDownload(_ model: LPModel) async throws -> Bool {
            guard let task = downloadTasks[model.modelId] else {
                throw LPError.downloadError(.noTaskFound)
            }
            
            return await withCheckedContinuation { continuation in
                task.cancel { [weak self] resumeDataOrNil in
                    guard let self = self else {
                        continuation.resume(returning: false)
                        return
                    }
                    
                    if let resumeData = resumeDataOrNil {
                        self.resumeData[model.modelId] = resumeData
                        self.pausedDownloads.insert(model.modelId)
                        self.downloadingModels.remove(model.modelId)
                        
                        continuation.resume(returning: true)
                    } else {
                        self.cancelDownload(model)
                        continuation.resume(returning: false)
                    }
                }
            }
        }
        
        @MainActor
        func resumeDownload(_ model: LPModel, downloadUrl: String, updateModelProgress: @escaping (String, Double) -> Void) async throws -> Bool {
            guard pausedDownloads.contains(model.modelId) else {
                throw LPError.downloadError(.notPaused)
            }
            
            return try await withCheckedThrowingContinuation { continuation in
                startDownload(model, downloadUrl: downloadUrl, updateModelProgress: updateModelProgress) { result in
                    switch result {
                    case .success(_):
                        self.resumeData.removeValue(forKey: model.modelId)
                        continuation.resume(returning: true)
                    case .failure(let error):
                        self.log("Failed to resume download: \(error)")
                        continuation.resume(returning: false)
                    }
                }
            }
        }
        
        func cancelDownload(_ model: LPModel) {
            downloadTasks[model.modelId]?.cancel()
            downloadTasks[model.modelId] = nil
            observations[model.modelId] = nil
            downloadingModels.remove(model.modelId)
            pausedDownloads.remove(model.modelId)
            resumeData.removeValue(forKey: model.modelId)
            downloadProgress.removeValue(forKey: model.modelId)
            
            completionHandlers[model.modelId]?(.failure(NSError(domain: "Download cancelled", code: 0, userInfo: nil)))
            completionHandlers.removeValue(forKey: model.modelId)
        }
        
        func getProgress(for modelId: String) -> Double {
            return downloadProgress[modelId] ?? 0.0
        }
        
        private func getApplicationSupportDirectoryURL() throws -> URL {
            let fileManager = FileManager.default
            return try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        }
        
        private func moveFile(from sourceURL: URL, to destinationURL: URL) throws {
            let fileManager = FileManager.default
            
            // Ensure the destination directory exists
            let destinationDirectory = destinationURL.deletingLastPathComponent()
            if !fileManager.fileExists(atPath: destinationDirectory.path) {
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true, attributes: nil)
            }
            
            // Remove existing file if it exists
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            
            // Move the file
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
            
            // Verify the file exists and is readable
            guard fileManager.fileExists(atPath: destinationURL.path) else {
                throw NSError(domain: "FileNotSaved", code: -1, userInfo: nil)
            }
            guard fileManager.isReadableFile(atPath: destinationURL.path) else {
                throw NSError(domain: "FileNotAccessible", code: -1, userInfo: nil)
            }
        }
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let modelId = downloadTask.taskDescription else { return }

            do {
                let applicationSupportDirectory = try getApplicationSupportDirectoryURL()
                let destinationURL = applicationSupportDirectory.appendingPathComponent(modelId)
                
                try moveFile(from: location, to: destinationURL)
                
                DispatchQueue.main.async { [weak self] in
                    self?.downloadingModels.remove(modelId)
                    self?.downloadTasks.removeValue(forKey: modelId)
                    self?.observations.removeValue(forKey: modelId)
                    self?.pausedDownloads.remove(modelId)
                    self?.downloadProgress[modelId] = 1.0
                    
                    // Call the completion handler
                    self?.completionHandlers[modelId]?(.success(destinationURL))
                    self?.completionHandlers.removeValue(forKey: modelId)
                }
            } catch {
                log("Error moving or verifying downloaded file: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.completionHandlers[modelId]?(.failure(error))
                    self?.completionHandlers.removeValue(forKey: modelId)
                }
            }
        }
        
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let downloadTask = task as? URLSessionDownloadTask,
                  let modelId = downloadTask.taskDescription else { return }
            
            if let error = error as NSError? {
                if error.code == NSURLErrorCancelled && resumeData[modelId] != nil { return }
                
                log("Download failed with error: \(error)")
                DispatchQueue.main.async { [weak self] in
                    self?.downloadingModels.remove(modelId)
                    self?.downloadTasks.removeValue(forKey: modelId)
                    self?.observations.removeValue(forKey: modelId)
                    self?.resumeData.removeValue(forKey: modelId)
                    
                    // Call the completion handler with the error
                    self?.completionHandlers[modelId]?(.failure(error))
                    self?.completionHandlers.removeValue(forKey: modelId)
                }
            }
        }
    }
    
    private class ChatManager: ObservableObject {
        // MARK: - Properties
        private var enableLogging: Bool = true
        private let benchmarkMemoryUsage: Double = 100.0 // MB
        private let benchmarkCPUUsage: Double = 50.0 // %
        private let benchmarkCompletionTime: TimeInterval = 5.0 // seconds
        private let NS_PER_S = 1_000_000_000.0
        
        private var llamaContext: LlamaContext?
        private var isInitialHeatUp = true
        
        @Published var memoryUsage: Double = 0
        @Published var cpuUsage: Double = 0
        @Published var completionTime: TimeInterval = 0
        
        private let contextSizeLimit: Int32 = 2048 // This should match the model's context size

        @Published var messages: [LPChatMessage] = []
        
        // MARK: - Initialization
        init(enableLogging: Bool = true) {
            self.enableLogging = enableLogging
        }
        
        // MARK: - Public Methods
        func clearContext() {
            llamaContext = nil
            messages.removeAll()
        }
        
        func clear() async {
            guard let llamaContext = llamaContext else { return }
            await llamaContext.clear()
            messages.removeAll()
        }
        
        func setContext(_ context: LlamaContext) {
            self.llamaContext = context
            isInitialHeatUp = true
        }
        
        func complete(messages: [LPChatMessage], model: LPModel, onToken: @escaping (String) -> Void) async throws {
            guard let llamaContext = llamaContext else { throw LPChatError.contextNotInitialized }

            self.messages = messages

            let startTime = Date()
            let initialMemory = getMemoryUsage()

            let formattedPrompt: String
            do { formattedPrompt = try await formatPrompt() } catch { throw LPChatError.tokenizationFailed }

            await llamaContext.completion_init(model: model, text: formattedPrompt)

            let generationStartTime = DispatchTime.now()

            let promptTokens = await llamaContext.get_n_tokens()
            let remainingTokens = max(0, contextSizeLimit - promptTokens)
            let maxTokens: Int32 = min(remainingTokens, 1000) // Limit to 1000 tokens or remaining context, whichever is smaller

            let specialTokens = specialTokensForModel(model.specialTokens)

            var accumulatedToken = ""
            var potentialStopSequence = ""
            var tokenCount: Int32 = 0
            var attempts = 0
            let maxAttempts = 3
            var isFirstContentToken = true
            var pendingWhitespace = ""
            var hasSeenAssistantTag = false
            
            let assistantStartToken = findAssistantStartToken(model: model)
            var hasSeenAssistantStartToken = false
            var accumulatedStartToken = ""

            while attempts < maxAttempts {
                while tokenCount < maxTokens {
                    let (result, isDone) = await llamaContext.completion_loop()
                    potentialStopSequence += result

                    // Check for complete stop tokens
                    if let completeStopToken = findCompleteStopToken(model: model, sequence: potentialStopSequence) {
                        pendingWhitespace = ""
                        break
                    }

                    // Handle the start token for assistant
                    if !hasSeenAssistantStartToken {
                        accumulatedStartToken += result
                        if accumulatedStartToken.hasSuffix(assistantStartToken) {
                            hasSeenAssistantStartToken = true
                            tokenCount += Int32(assistantStartToken.utf8.count)
                            potentialStopSequence = String(potentialStopSequence.dropLast(assistantStartToken.count))
                            accumulatedStartToken = ""
                            continue
                        }
                    }

                    // Process tokens that are not part of stop sequences
                    let (processedToken, remainingSequence) = processNonStopTokens(model: model, sequence: potentialStopSequence)
                    potentialStopSequence = remainingSequence

                    if !processedToken.isEmpty {
                        if processedToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            if !isFirstContentToken {
                                pendingWhitespace += processedToken
                            }
                        } else {
                            if isFirstContentToken {
                                let trimmedToken = processedToken.trimmingCharacters(in: .whitespaces)
                                onToken(trimmedToken)
                                accumulatedToken += trimmedToken
                                tokenCount += Int32(trimmedToken.utf8.count)
                                isFirstContentToken = false
                            } else if !pendingWhitespace.isEmpty {
                                onToken(pendingWhitespace)
                                accumulatedToken += pendingWhitespace
                                tokenCount += Int32(pendingWhitespace.utf8.count)
                                pendingWhitespace = ""
                            } else {
                                onToken(processedToken)
                                accumulatedToken += processedToken
                                tokenCount += Int32(processedToken.utf8.count)
                            }
                        }
                    }

                    if isDone {
                        log("Generation complete or stopped")
                        break
                    }

                    if await llamaContext.n_cur % 10 == 0 {
                        await updateMetrics()
                    }
                }

                if !accumulatedToken.isEmpty {
                    break
                } else {
                    attempts += 1
                    tokenCount = 0
                    accumulatedToken = ""
                    potentialStopSequence = ""
                    pendingWhitespace = ""
                    isFirstContentToken = true
                    hasSeenAssistantTag = false
                    await llamaContext.completion_init(model: model, text: formattedPrompt)
                }
            }

            if accumulatedToken.isEmpty {
                log("Failed to generate a non-empty response after \(maxAttempts) attempts.")
            }

            let generationEndTime = DispatchTime.now()
            let t_generation = Double(generationEndTime.uptimeNanoseconds - generationStartTime.uptimeNanoseconds) / Double(NSEC_PER_SEC)
            
            let tokens_per_second = t_generation > 0 ? Double(tokenCount) / t_generation : 0
            
            let finalMemory = getMemoryUsage()
            
            completionTime = Date().timeIntervalSince(startTime)
            let systemMessage = formatMetrics(t_heat: 0, tokens_per_second: tokens_per_second, finalMemory: finalMemory - initialMemory)
            log(systemMessage)
            self.messages.append(LPChatMessage(role: .system, content: systemMessage))
            
            if isInitialHeatUp { isInitialHeatUp = false }
        }
        
        // LEFT OFF: Remove this hard code. If needed - do more testing
        func findAssistantStartToken(model: LPModel) -> String {
            let specialTokens = specialTokensForModel(model.specialTokens)
            return specialTokens.start.first(where: { $0.contains("assistant") }) ?? "<|im_start|>assistant"
        }
        
        func findCompleteStopToken(model: LPModel, sequence: String) -> String? {
            let specialTokens = specialTokensForModel(model.specialTokens)
            return specialTokens.stop.first { sequence.hasSuffix($0) }
        }

        func processNonStopTokens(model: LPModel, sequence: String) -> (processedToken: String, remainingSequence: String) {
            let specialTokens = specialTokensForModel(model.specialTokens)
            let stopTokenPrefixes = Set(specialTokens.stop.compactMap { $0.first.map(String.init) })
            
            var processedToken = ""
            var remainingSequence = sequence
            
            while !remainingSequence.isEmpty {
                if let firstChar = remainingSequence.first, stopTokenPrefixes.contains(String(firstChar)) {
                    break
                }
                processedToken.append(remainingSequence.removeFirst())
            }
            
            return (processedToken, remainingSequence)
        }

        func specialTokensForModel(_ specialTokens: String) -> (start: [String], stop: [String]) {
            guard let data = specialTokens.data(using: .utf8),
                  let json = try? JSONDecoder().decode([String: [String]].self, from: data),
                  let startTokens = json["start"],
                  let stopTokens = json["stop"] else {
                return ([], [])
            }
            return (start: startTokens, stop: stopTokens)
        }
        
        // MARK: - Private Methods
        private func log(_ message: String) { if enableLogging { print("[Lightpack] \(message)") } }
        
        private func formatPrompt() async throws -> String {
            guard let llamaContext = llamaContext else {
                throw LPChatError.contextNotInitialized
            }

            let model = await llamaContext.getModel()

            // Convert messages to llama_chat_message format
            var llamaMessages = messages.map { message -> llama_chat_message in
                let roleCString = strdup(message.role.rawValue)
                let contentCString = strdup(message.content)
                return llama_chat_message(
                    role: roleCString,
                    content: contentCString
                )
            }

            let bufferSize = 16384
            var buffer = [CChar](repeating: 0, count: bufferSize)

            // Call llama_chat_apply_template
            let result = llama_chat_apply_template(
                model,
                nil,
                &llamaMessages,  // Pass the address of the first element
                llamaMessages.count,
                false,
                &buffer,
                Int32(bufferSize)
            )

            if result < 0 {
                throw LPChatError.promptFormattingFailed
            }

            let formattedPrompt = String(cString: buffer)

            // Clean up allocated memory
            for message in llamaMessages {
                free(UnsafeMutablePointer(mutating: message.role))
                free(UnsafeMutablePointer(mutating: message.content))
            }

            // Fallback: If the formatted prompt is empty, create a basic format
            if formattedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let fallbackPrompt = messages.map { "\($0.role.rawValue): \($0.content)" }.joined(separator: "\n")
                return fallbackPrompt
            }

            return formattedPrompt
        }
        
        private func getPerformanceLabel(value: Double, benchmark: Double, lowerIsBetter: Bool) -> String {
            let percentage = (value / benchmark) * 100
            let comparison = lowerIsBetter ? benchmark > value : benchmark < value
            if abs(percentage - 100) <= 10 { return "(Average)" }
            return comparison ? "(Good)" : "(Needs Improvement)"
        }
        
        private func updateMetrics() async {
            memoryUsage = max(memoryUsage, getMemoryUsage())
            cpuUsage = getCPUUsage()
        }
        
        private func getMemoryUsage() -> Double {
            var taskInfo = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size) / 4
            let result: kern_return_t = withUnsafeMutablePointer(to: &taskInfo) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            return result == KERN_SUCCESS ? Double(taskInfo.phys_footprint) / 1024.0 / 1024.0 : 0
        }
        
        private func getCPUUsage() -> Double {
            var threadList: thread_act_array_t?
            var threadCount: mach_msg_type_number_t = 0
            let result = task_threads(mach_task_self_, &threadList, &threadCount)
            
            guard result == KERN_SUCCESS, let threadList = threadList else { return 0 }
            
            var totalCPU: Double = 0
            for i in 0..<Int(threadCount) {
                var threadInfo = thread_basic_info()
                var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
                let infoResult = withUnsafeMutablePointer(to: &threadInfo) {
                    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                        thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
                    }
                }
                if infoResult == KERN_SUCCESS {
                    totalCPU += Double(threadInfo.cpu_usage) / Double(TH_USAGE_SCALE) * 100.0
                }
            }
            
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), vm_size_t(Int(threadCount) * MemoryLayout<thread_act_t>.stride))
            
            return totalCPU
        }
        
        private func formatMetrics(t_heat: Double, tokens_per_second: Double, finalMemory: Double) -> String {
      """
      
      \(isInitialHeatUp ? "Initial heat up" : "Heat up") took \(String(format: "%.2f", t_heat))s
      Generated in \(String(format: "%.2f", tokens_per_second)) t/s
      Total time: \(String(format: "%.2f", completionTime))s \(getPerformanceLabel(value: completionTime, benchmark: benchmarkCompletionTime, lowerIsBetter: true))
      Memory usage: \(String(format: "%.2f", finalMemory)) MB \(getPerformanceLabel(value: finalMemory, benchmark: benchmarkMemoryUsage, lowerIsBetter: true))
      Peak memory: \(String(format: "%.2f", memoryUsage)) MB \(getPerformanceLabel(value: memoryUsage, benchmark: benchmarkMemoryUsage, lowerIsBetter: true))
      Average CPU: \(String(format: "%.2f", cpuUsage))% \(getPerformanceLabel(value: cpuUsage, benchmark: benchmarkCPUUsage, lowerIsBetter: true))
      """
        }
        
        private func measureTime(block: () -> Void) -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            block()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / NS_PER_S
        }
        
        private func measureAsyncTime(block: @escaping () async -> Void) async -> Double {
            let start = DispatchTime.now().uptimeNanoseconds
            await block()
            return Double(DispatchTime.now().uptimeNanoseconds - start) / NS_PER_S
        }
    }
    
    enum LlamaError: Error {
        case couldNotInitializeContext
    }

    actor LlamaContext {
        private var enableLogging: Bool
        private func log(_ message: String) { if enableLogging { print("[Lightpack] \(message)") } }

        private var model: OpaquePointer
        private var context: OpaquePointer
        private var sampling: UnsafeMutablePointer<llama_sampler>
        private var batch: llama_batch
        private var tokens_list: [llama_token]
        
        var is_done: Bool = false
        var specialTokens: String? = nil

        /// This variable is used to store temporarily invalid cchars
        private var temporary_invalid_cchars: [CChar]

        var n_len: Int32 = 1024
        var n_cur: Int32 = 0

        var n_decode: Int32 = 0

        init(model: OpaquePointer, context: OpaquePointer, enableLogging: Bool = true) {
            self.model = model
            self.context = context
            self.enableLogging = enableLogging
            self.tokens_list = []
            self.batch = llama_batch_init(512, 0, 1)
            self.temporary_invalid_cchars = []
            let sparams = llama_sampler_chain_default_params()
            self.sampling = llama_sampler_chain_init(sparams)
            llama_sampler_chain_add(self.sampling, llama_sampler_init_temp(0.4))
            llama_sampler_chain_add(self.sampling, llama_sampler_init_softmax())
            llama_sampler_chain_add(self.sampling, llama_sampler_init_dist(1234))
        }

        deinit {
            llama_sampler_free(sampling)
            llama_batch_free(batch)
            llama_free(context)
            llama_free_model(model)
            llama_backend_free()
        }
        
        func getModel() -> OpaquePointer {
            return model
        }

        static func create_context(path: String, enableLogging: Bool = true) throws -> LlamaContext {
            llama_backend_init()
            var model_params = llama_model_default_params()

    #if targetEnvironment(simulator)
            model_params.n_gpu_layers = 0
            if enableLogging { print("Running on simulator, force use n_gpu_layers = 0") }
    #endif
            let model = llama_load_model_from_file(path, model_params)
            guard let model else {
                if enableLogging { print("Could not load model at \(path)") }
                throw LlamaError.couldNotInitializeContext
            }

            let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
            if enableLogging { print("Using \(n_threads) threads") }

            var ctx_params = llama_context_default_params()
            ctx_params.n_ctx = 2048
            ctx_params.n_threads       = Int32(n_threads)
            ctx_params.n_threads_batch = Int32(n_threads)

            let context = llama_new_context_with_model(model, ctx_params)
            guard let context else {
                if enableLogging { print("Could not load context!") }
                throw LlamaError.couldNotInitializeContext
            }

            return LlamaContext(model: model, context: context, enableLogging: enableLogging)
        }

        func model_info() -> String {
            let result = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
            result.initialize(repeating: Int8(0), count: 256)
            defer { result.deallocate() }

            let nChars = llama_model_desc(model, result, 256)
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nChars))

            var SwiftString = ""
            for char in bufferPointer { SwiftString.append(Character(UnicodeScalar(UInt8(char)))) }

            return SwiftString
        }

        func get_n_tokens() -> Int32 { return batch.n_tokens }

        func completion_init(model: LPModel, text: String) {
            specialTokens = model.specialTokens

            tokens_list = tokenize(text: text, add_bos: true)
            temporary_invalid_cchars = []

            let n_ctx = llama_n_ctx(context)
            let n_kv_req = tokens_list.count + (Int(n_len) - tokens_list.count)

//            log("\n n_len = \(n_len), n_ctx = \(n_ctx), n_kv_req = \(n_kv_req)")

            if n_kv_req > n_ctx {
                log("error: n_kv_req > n_ctx, the required KV cache size is not big enough")
            }

            llama_batch_clear(&batch)

            for i1 in 0..<tokens_list.count {
                let i = Int(i1)
                llama_batch_add(&batch, tokens_list[i], Int32(i), [0], false)
            }
            batch.logits[Int(batch.n_tokens) - 1] = 1 // true

            if llama_decode(context, batch) != 0 { log("llama_decode() failed") }

            n_cur = batch.n_tokens
        }

        func completion_loop() -> (String, Bool) {
            var new_token_id: llama_token = 0

            new_token_id = llama_sampler_sample(sampling, context, batch.n_tokens - 1)
            
            if llama_token_is_eog(model, new_token_id) || n_cur == n_len {
                print("\n")
                is_done = true
                let new_token_str = String(cString: temporary_invalid_cchars + [0])
                temporary_invalid_cchars.removeAll()
                return (new_token_str, true)
            }

            let new_token_cchars = token_to_piece(token: new_token_id)
            temporary_invalid_cchars.append(contentsOf: new_token_cchars)
            let new_token_str: String
            if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
                temporary_invalid_cchars.removeAll()
                new_token_str = string
            } else if (0 ..< temporary_invalid_cchars.count).contains(where: {$0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil}) {
                let string = String(cString: temporary_invalid_cchars + [0])
                temporary_invalid_cchars.removeAll()
                new_token_str = string
            } else {
                new_token_str = ""
            }

            llama_batch_clear(&batch)
            llama_batch_add(&batch, new_token_id, n_cur, [0], true)

            n_decode += 1
            n_cur    += 1

            if llama_decode(context, batch) != 0 {
                print("failed to evaluate llama!")
            }

            return (new_token_str, false)
        }

        func bench(pp: Int, tg: Int, pl: Int, nr: Int = 1) -> String {
            var pp_avg: Double = 0
            var tg_avg: Double = 0

            var pp_std: Double = 0
            var tg_std: Double = 0

            for _ in 0..<nr {
                // bench prompt processing

                llama_batch_clear(&batch)

                let n_tokens = pp

                for i in 0..<n_tokens {
                    llama_batch_add(&batch, 0, Int32(i), [0], false)
                }
                batch.logits[Int(batch.n_tokens) - 1] = 1 // true

                llama_kv_cache_clear(context)

                let t_pp_start = ggml_time_us()

                if llama_decode(context, batch) != 0 { log("llama_decode() failed during prompt") }
                llama_synchronize(context)

                let t_pp_end = ggml_time_us()

                // bench text generation

                llama_kv_cache_clear(context)

                let t_tg_start = ggml_time_us()

                for i in 0..<tg {
                    llama_batch_clear(&batch)

                    for j in 0..<pl { llama_batch_add(&batch, 0, Int32(i), [Int32(j)], true) }

                    if llama_decode(context, batch) != 0 { log("llama_decode() failed during text generation") }
                    llama_synchronize(context)
                }

                let t_tg_end = ggml_time_us()

                llama_kv_cache_clear(context)

                let t_pp = Double(t_pp_end - t_pp_start) / 1000000.0
                let t_tg = Double(t_tg_end - t_tg_start) / 1000000.0

                let speed_pp = Double(pp)    / t_pp
                let speed_tg = Double(pl*tg) / t_tg

                pp_avg += speed_pp
                tg_avg += speed_tg

                pp_std += speed_pp * speed_pp
                tg_std += speed_tg * speed_tg

                log("pp \(speed_pp) t/s, tg \(speed_tg) t/s")
            }

            pp_avg /= Double(nr)
            tg_avg /= Double(nr)

            if nr > 1 {
                pp_std = sqrt(pp_std / Double(nr - 1) - pp_avg * pp_avg * Double(nr) / Double(nr - 1))
                tg_std = sqrt(tg_std / Double(nr - 1) - tg_avg * tg_avg * Double(nr) / Double(nr - 1))
            } else {
                pp_std = 0
                tg_std = 0
            }

            let model_desc     = model_info();
            let model_size     = String(format: "%.2f GiB", Double(llama_model_size(model)) / 1024.0 / 1024.0 / 1024.0);
            let model_n_params = String(format: "%.2f B", Double(llama_model_n_params(model)) / 1e9);
            let backend        = getBackendInfo();
            let pp_avg_str     = String(format: "%.2f", pp_avg);
            let tg_avg_str     = String(format: "%.2f", tg_avg);
            let pp_std_str     = String(format: "%.2f", pp_std);
            let tg_std_str     = String(format: "%.2f", tg_std);

            var result = ""

            result += String("| model | size | params | backend | test | t/s |\n")
            result += String("| --- | --- | --- | --- | --- | --- |\n")
            result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | pp \(pp) | \(pp_avg_str) ± \(pp_std_str) |\n")
            result += String("| \(model_desc) | \(model_size) | \(model_n_params) | \(backend) | tg \(tg) | \(tg_avg_str) ± \(tg_std_str) |\n")

            return result;
        }

        func clear() {
            tokens_list.removeAll()
            temporary_invalid_cchars.removeAll()
            llama_kv_cache_clear(context)
        }

        func tokenize(text: String, add_bos: Bool) -> [llama_token] {
            let utf8Count = text.utf8.count
            let n_tokens = utf8Count + (add_bos ? 1 : 0) + 1
            let tokens = UnsafeMutablePointer<llama_token>.allocate(capacity: n_tokens)
            let tokenCount = llama_tokenize(model, text, Int32(utf8Count), tokens, Int32(n_tokens), add_bos, false)

            var swiftTokens: [llama_token] = []
            for i in 0..<tokenCount { swiftTokens.append(tokens[Int(i)]) }

            tokens.deallocate()

            return swiftTokens
        }

        /// - note: The result does not contain null-terminator
        private func token_to_piece(token: llama_token) -> [CChar] {
            let result = UnsafeMutablePointer<Int8>.allocate(capacity: 8)
            result.initialize(repeating: Int8(0), count: 8)
            defer { result.deallocate() }
            let nTokens = llama_token_to_piece(model, token, result, 8, 0, false)

            if nTokens < 0 {
                let newResult = UnsafeMutablePointer<Int8>.allocate(capacity: Int(-nTokens))
                newResult.initialize(repeating: Int8(0), count: Int(-nTokens))
                defer { newResult.deallocate() }
                let nNewTokens = llama_token_to_piece(model, token, newResult, -nTokens, 0, false)
                let bufferPointer = UnsafeBufferPointer(start: newResult, count: Int(nNewTokens))
                return Array(bufferPointer)
            } else {
                let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nTokens))
                return Array(bufferPointer)
            }
        }
        
        func llama_batch_clear(_ batch: inout llama_batch) {
            batch.n_tokens = 0
        }

        func llama_batch_add(_ batch: inout llama_batch, _ id: llama_token, _ pos: llama_pos, _ seq_ids: [llama_seq_id], _ logits: Bool) {
            batch.token   [Int(batch.n_tokens)] = id
            batch.pos     [Int(batch.n_tokens)] = pos
            batch.n_seq_id[Int(batch.n_tokens)] = Int32(seq_ids.count)
            for i in 0..<seq_ids.count { batch.seq_id[Int(batch.n_tokens)]![Int(i)] = seq_ids[i] }
            batch.logits  [Int(batch.n_tokens)] = logits ? 1 : 0

            batch.n_tokens += 1
        }
        
        func getBackendInfo() -> String {
    #if targetEnvironment(simulator)
            return "CPU (Simulator)"
    #else
            let device = MTLCreateSystemDefaultDevice()
            if let name = device?.name {
                if name.contains("Apple") {
                    return "Apple GPU (\(name))"
                } else {
                    return "GPU (\(name))"
                }
            } else { return "CPU" }
    #endif
        }
    }
}
