import Foundation
import llama
import Metal

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

public let lightpackVersion = "0.0.2"

@available(macOS 10.15, iOS 13.0, watchOS 6.0, tvOS 13.0, *)
public class Lightpack: LightpackProtocol, ObservableObject {
    @Published public private(set) var models: [String: LPModel] = [:]
    @Published public private(set) var families: [String: LPModelFamily] = [:]
    @Published public private(set) var loadedModel: LPModel?
    @Published public private(set) var totalModelSize: Float = 0.0
    
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
       
       Task { await loadModelMetadata() }
   }
    
    private func loadModelMetadata() async {
        log("Load model metadata")
        guard let data = UserDefaults.standard.data(forKey: userDefaultsModelMetadataKey) else {
            log("No model metadata found in UserDefaults")
            return
        }
        
        do {
            let modelMetadata = try JSONDecoder().decode(LPModelMetadataResponse.self, from: data)
            guard !modelMetadata.models.isEmpty else {
                log("Decoded model metadata is empty")
                return
            }
            
            DispatchQueue.main.async {
                self.models = modelMetadata.models
                self.families = modelMetadata.familyModels
            }
            
            // Update model statuses based on downloaded files
            let fileManager = FileManager.default
            let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            
            if !fileManager.fileExists(atPath: applicationSupportDirectory.path) {
                do {
                    try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true, attributes: nil)
                } catch {
                    log("Error creating Application Support directory: \(error.localizedDescription)", true)
                }
            }
            
            do {
                let fileURLs = try fileManager.contentsOfDirectory(at: applicationSupportDirectory, includingPropertiesForKeys: nil)
                for fileURL in fileURLs {
                    let modelId = fileURL.lastPathComponent
                    if var model = self.models[modelId] {
                        model.status = .downloaded
                        self.models[modelId] = model
                    }
                }
            } catch {
                log("Error while enumerating files: \(error.localizedDescription)", true)
            }
            
            updateTotalModelSize()
        } catch {
            log("Error decoding model data: \(error)", true)
        }
    }
    
    private func saveAndMergeModelMetadata(models: [LPModel]?, families: [LPModelFamily]?) {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        
        // Fetch existing metadata
        var existingMetadata: LPModelMetadataResponse?
        if let data = UserDefaults.standard.data(forKey: userDefaultsModelMetadataKey) {
            existingMetadata = try? decoder.decode(LPModelMetadataResponse.self, from: data)
        }
        
        // Merge models
        var mergedModels: [String: LPModel] = existingMetadata?.models ?? [:]
        if let newModels = models {
            for model in newModels {
                if let existingModel = mergedModels[model.modelId] {
                    // Preserve the existing status and downloadProgress
                    var updatedModel = model
                    updatedModel.status = existingModel.status
                    updatedModel.downloadProgress = existingModel.downloadProgress
                    
                    // Check if the model is outdated
                    if isModelOutdated(existingModel, model) {
                        updatedModel.status = .outdated
                    }
                    
                    mergedModels[model.modelId] = updatedModel
                } else {
                    mergedModels[model.modelId] = model
                }
            }
        }
        
        // Merge families
        var mergedFamilies: [String: LPModelFamily] = existingMetadata?.familyModels ?? [:]
        if let newFamilies = families {
            for family in newFamilies {
                mergedFamilies[family.familyId] = family
            }
        }
        
        // Create new metadata response
        let newMetadata = LPModelMetadataResponse(
            familyModels: mergedFamilies,
            models: mergedModels,
            updatedAt: ISO8601DateFormatter().string(from: Date())
        )
        
        // Save to UserDefaults
        if let encodedData = try? encoder.encode(newMetadata) {
            UserDefaults.standard.set(encodedData, forKey: userDefaultsModelMetadataKey)
        }
        
        // Update the current models and families
        DispatchQueue.main.async {
            self.models = mergedModels
            self.families = mergedFamilies
        }
    }
    
    private func checkNetworkConnectivity() throws {
        guard LPNetworkMonitor.shared.isConnected else {
            throw LPError.networkError(NSError(domain: "No network connection", code: 0, userInfo: nil))
        }
    }
    
    private func getModel(_ modelId: String) async throws -> LPModel {
        log("Get model \(modelId)")
        guard modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw LPError.modelIsEmpty }

        if let model = models[modelId] {
            // Check if the model file exists
            let fileManager = FileManager.default
            let modelFilePath = getFileURL(modelId).path
            
            if fileManager.fileExists(atPath: modelFilePath) {
                if model.status != .downloaded {
                    updateModelStatus(modelId: modelId, newStatus: .downloaded)
                }
                return models[modelId]!  // Return the updated model
            } else if model.status == .downloaded {
                // File doesn't exist but status is downloaded, update status
                updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
            }
            // Return the model even if it's not downloaded
            return model
        }
        
        // Model not found locally, try to fetch from API
        try checkNetworkConnectivity()
        return try await withCheckedThrowingContinuation { continuation in
            getModels(modelIds: [modelId]) { result in
                switch result {
                case .success((let response, _)):
                    if let model = response.models.first {
                        continuation.resume(returning: model)
                    } else {
                        continuation.resume(throwing: LPError.modelNotFound)
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    public func loadModel(_ modelId: String) async throws {
        log("Load model \(modelId)")
        
        do {
            guard modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw LPError.modelIsEmpty }
            let model = try await getModel(modelId)
            
            if model.status == .downloaded && modelId == loadedModel?.modelId { return }
            
            if model.status == .notDownloaded {
                try await downloadModel(modelId)
            } else if case .paused = model.status {
                try await resumeDownloadModel(modelId)
            }
            
            let startTime = DispatchTime.now()
            let modelUrl = getFileURL(modelId)
            let context = try LlamaContext.create_context(path: modelUrl.path)
            chatManager.setContext(context)
            
            DispatchQueue.main.async {
                self.loadedModel = model
            }
            
            let loadTime = Double(DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000_000.0
            let backend = await context.getBackendInfo()
            
            log("\(model.title) loaded in \(String(format: "%.2f", loadTime))s from \(backend)")
            
            sendApiEvent(.loadModel, data: ["modelId": modelId])
        } catch {
            log("Error loading model: \(error)", true)
            throw error // Propagate the error up
        }
    }

    public func downloadModel(_ modelId: String) async throws {
        log("Download model \(modelId)")
        
        do {
            try checkNetworkConnectivity()
            
            guard modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw LPError.modelIsEmpty
            }

            let model = try await getModel(modelId)
            
            if model.status == .downloaded {
                log("Model \(modelId) is already downloaded.")
                return
            }
            
            updateModelStatus(modelId: modelId, newStatus: .downloading)
            updateModelProgress(modelId: modelId, progress: downloadManager.getProgress(for: modelId))
            
            let downloadUrl: String
            if model.downloadUrl == nil {
                downloadUrl = try await getModelDownloadUrl(modelId: modelId)
                updateModelDownloadUrl(modelId: modelId, downloadUrl: downloadUrl)
            } else {
                downloadUrl = model.downloadUrl!
            }
            
            _ = try await downloadManager.downloadModel(model, downloadUrl: downloadUrl) { [weak self] modelId, progress in
                self?.updateModelProgress(modelId: modelId, progress: progress)
            }
            updateModelStatus(modelId: modelId, newStatus: .downloaded)
            updateTotalModelSize()
            
            var updatedModel = model
            updatedModel.status = .downloaded
            saveAndMergeModelMetadata(models: [updatedModel], families: nil)
            
            sendApiEvent(.downloadModel, data: ["modelId": modelId])
        } catch {
            log("Error downloading model: \(error)", true)
            updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
            updateModelProgress(modelId: modelId, progress: 0)
            throw error
        }
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
    
    public func pauseDownloadModel(_ modelId: String) async throws {
        log("Pause download model \(modelId)")
        do {
            guard modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw LPError.modelIsEmpty }
            let model = try await getModel(modelId)
            let success = try await downloadManager.pauseDownload(model)
            if success {
                let progress = downloadManager.getProgress(for: modelId)
                updateModelStatus(modelId: modelId, newStatus: .paused)
                updateModelProgress(modelId: modelId, progress: progress)
            } else {
                log("Failed to pause download for model: \(modelId)")
                updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
            }
            
            sendApiEvent(.pauseDownloadModel, data: ["modelId": modelId])
            
            return
        } catch {
            log("Error pausing download: \(error)", true)
            throw error
        }
    }
    
    @MainActor
    public func resumeDownloadModel(_ modelId: String) async throws {
        log("Resume download model \(modelId)")
        try checkNetworkConnectivity()
        
        do {
            guard modelId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { throw LPError.modelIsEmpty }
            let model = try await getModel(modelId)
            updateModelStatus(modelId: modelId, newStatus: .downloading)
            
            guard let downloadUrl = model.downloadUrl else {
                throw LPError.downloadError(.noDownloadUrl)
            }
            
            let success = try await downloadManager.resumeDownload(model, downloadUrl: downloadUrl) { [weak self] modelId, progress in
                self?.updateModelProgress(modelId: modelId, progress: progress)
            }
            if success {
                updateModelStatus(modelId: modelId, newStatus: .downloading)
                updateTotalModelSize()
            } else {
                log("Failed to resume download for model: \(modelId)")
                updateModelStatus(modelId: modelId, newStatus: .paused)
            }
            
            sendApiEvent(.resumeDownloadModel, data: ["modelId": modelId])
            
            return
        } catch {
            log("Error resuming download: \(error)", true)
            updateModelStatus(modelId: modelId, newStatus: .paused)
            throw error
        }
    }
    
    public func cancelDownloadModel(_ modelId: String) async throws {
        log("Cancel download model \(modelId)")
        do {
            let model = try await getModel(modelId)
            log("Cancel download for model \(modelId)")
            downloadManager.cancelDownload(model)
            updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
            updateModelProgress(modelId: modelId, progress: 0)
            objectWillChange.send()
            
            sendApiEvent(.cancelDownloadModel, data: ["modelId": modelId])
            
            return
        } catch {
            log("Error cancelling download: \(error)", true)
            updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
            throw error
        }
    }
    
    public func removeModels(modelIds: [String]? = nil, removeAll: Bool = false) async throws {
        log("Removing models: \(modelIds ?? []), removeAll: \(removeAll)")
        
        let fileManager = FileManager.default
        let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        
        // Early return if no action is required
        guard removeAll || (modelIds != nil && !modelIds!.isEmpty) else {
            log("No models to remove")
            return
        }
        
        do {
            let fileURLs = try fileManager.contentsOfDirectory(at: applicationSupportDirectory, includingPropertiesForKeys: nil)
            var removedModelIds: [String] = []
            
            if removeAll {
                // Remove all models
                for fileURL in fileURLs {
                    try fileManager.removeItem(at: fileURL)
                    let modelId = fileURL.lastPathComponent
                    updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
                    removedModelIds.append(modelId)
                }
                
                // Reset all model statuses
                for modelId in models.keys {
                    updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
                }
            } else if let modelIds = modelIds {
                // Remove specific models
                for modelId in modelIds {
                    let fileURL = getFileURL(modelId)
                    if fileURLs.contains(fileURL) {
                        try fileManager.removeItem(at: fileURL)
                        updateModelStatus(modelId: modelId, newStatus: .notDownloaded)
                        removedModelIds.append(modelId)
                    } else {
                        log("Model file not found: \(modelId)")
                    }
                }
            }
            
            updateTotalModelSize()
            objectWillChange.send()
            
            if removeAll { chatManager.clearContext() }

            let removedModelIdsCopy = removedModelIds
            Task(priority: .background) {
                var data: [String: Any] = [:]
                if !removedModelIdsCopy.isEmpty {
                    data["modelIds"] = removedModelIdsCopy.joined(separator: ",")
                }
                if removeAll { data["removeAll"] = removeAll }
                self.sendApiEvent(.removeModels, data: data)
            }
        } catch {
            log("Error while removing models: \(error.localizedDescription)", true)
            throw error
        }
    }

    private func getFileURL(_ modelId: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(modelId)
    }
    
    private func updateModelStatus(modelId: String, newStatus: LPModelStatus) {
        log("Update model status \(modelId) to \(newStatus)")
        if var model = models[modelId] {
            model.status = newStatus
            models[modelId] = model
            saveModelMetadata()
            DispatchQueue.main.async {
                self.objectWillChange.send()
            }
        }
    }

    private func saveModelMetadata() {
        let encoder = JSONEncoder()
        if let encodedData = try? encoder.encode(LPModelMetadataResponse(familyModels: families, models: models, updatedAt: ISO8601DateFormatter().string(from: Date()))) {
            UserDefaults.standard.set(encodedData, forKey: userDefaultsModelMetadataKey)
        }
    }

    private func updateModelProgress(modelId: String, progress: Double) {
        log("Update model progress \(modelId) to \(progress)")
        if var model = models[modelId] {
            model.downloadProgress = progress
            models[modelId] = model
            if progress >= 1.0 {
                updateModelStatus(modelId: modelId, newStatus: .downloaded)
            }
            objectWillChange.send()
        }
    }
    
    private func updateTotalModelSize() {
        DispatchQueue.main.async {
            self.totalModelSize = self.models.values
                .filter { $0.status == .downloaded }
                .map { Float($0.size) }
                .reduce(0.0 as Float, +)
        }
    }
    
    private func isModelOutdated(_ localModel: LPModel, _ remoteModel: LPModel) -> Bool {
        guard let localDate = ISO8601DateFormatter().date(from: localModel.updatedAt),
              let remoteDate = ISO8601DateFormatter().date(from: remoteModel.updatedAt) else {
            return false // If we can't parse the dates, assume the model is not outdated
        }
        return remoteDate > localDate
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
    
    public func clearChat() async {
        chatManager.clearContext()
        sendApiEvent(.clearChat)
    }
    
    public func chatModel(_ modelId: String? = nil, messages: [LPChatMessage], onToken: @escaping (String) -> Void) async throws {
        do {
            let validModelId = cleanModelId(modelId)
            log("Chat model \(validModelId)")
            try await loadModel(validModelId)
            
            try await chatManager.complete(messages: messages, onToken: onToken)
            
            sendApiEvent(.chatModel, data: ["modelId": validModelId])
            
            return
        } catch {
            log("Error in chat model: \(error)", true)
            throw error
        }
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
        
        // Validate and add numeric parameters
        if let bitMax = bitMax, bitMax > 0 { parameters["bitMax"] = String(bitMax) }
        if let bitMin = bitMin, bitMin > 0 { parameters["bitMin"] = String(bitMin) }
        if let page = page, page > 0 { parameters["page"] = String(page) }
        if let pageSize = pageSize, pageSize > 0 { parameters["pageSize"] = String(pageSize) }
        if let sizeMax = sizeMax, sizeMax > 0 { parameters["sizeMax"] = String(sizeMax) }
        if let sizeMin = sizeMin, sizeMin > 0 { parameters["sizeMin"] = String(sizeMin) }
        
        // Clean and add array parameters
        if let familyIds = cleanAndJoinArray(familyIds) { parameters["familyIds"] = familyIds }
        if let modelIds = cleanAndJoinArray(modelIds) { parameters["modelIds"] = modelIds }
        if let parameterIds = cleanAndJoinArray(parameterIds) { parameters["parameterIds"] = parameterIds }
        if let quantizationIds = cleanAndJoinArray(quantizationIds) { parameters["quantizationIds"] = quantizationIds }
        
        // Validate and add sort parameter
        if let sort = sort?.trimmingCharacters(in: .whitespacesAndNewlines), !sort.isEmpty { parameters["sort"] = sort }
        
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
        familyIds: [String]? = nil,
        modelParameterIds: [String]? = nil,
        page: Int? = nil,
        pageSize: Int? = nil,
        sort: String? = nil,
        completion: @escaping (Result<(LPModelFamiliesResponse, [String]), LPError>) -> Void
    ) {
        var parameters: [String: String] = [:]
        
        // Clean and add array parameters
        if let familyIds = cleanAndJoinArray(familyIds) { parameters["familyIds"] = familyIds }
        if let modelParameterIds = cleanAndJoinArray(modelParameterIds) { parameters["modelParameterIds"] = modelParameterIds }
        
        // Validate and add numeric parameters
        if let page = page, page > 0 { parameters["page"] = String(page) }
        if let pageSize = pageSize, pageSize > 0 { parameters["pageSize"] = String(pageSize) }
        
        // Validate and add sort parameter
        if let sort = sort?.trimmingCharacters(in: .whitespacesAndNewlines), !sort.isEmpty {
            parameters["sort"] = sort
        }
        
        performRequest(parameters: parameters, apiType: .getModelFamilies) { [weak self] (result: Result<LPModelFamiliesResponse, LPError>) in
            switch result {
            case .success(let response):
                let updatedFamilies = self?.checkForFamilyUpdates(remoteFamilies: response.modelFamilies) ?? []
                self?.saveAndMergeModelMetadata(models: nil, families: response.modelFamilies)
                completion(.success((response, updatedFamilies)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    private func getModelDownload(
        modelId: String,
        completion: @escaping (Result<LPModelDownloadResponse, LPError>) -> Void
    ) {
        let trimmedModelId = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelId.isEmpty else {
            completion(.failure(.invalidInput("ModelId is required and cannot be empty")))
            return
        }

        let parameters = ["modelId": trimmedModelId]
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
                DispatchQueue.main.async {
                    self.downloadProgress[model.modelId] = observedProgress.fractionCompleted
                    updateModelProgress(model.modelId, observedProgress.fractionCompleted)
                }
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
        
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            guard let modelId = downloadTask.taskDescription else { return }
            
            let fileManager = FileManager.default
            let applicationSupportDirectory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let destinationURL = applicationSupportDirectory.appendingPathComponent(modelId)
            
            do {
                // Ensure the application support directory exists
                if !fileManager.fileExists(atPath: applicationSupportDirectory.path) {
                    try fileManager.createDirectory(at: applicationSupportDirectory, withIntermediateDirectories: true, attributes: nil)
                }
                
                // If the file already exists, remove it before moving the new one
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                
                // Move the downloaded file to the application support directory
                try fileManager.moveItem(at: location, to: destinationURL)
                
                // Verify that the file exists and is readable
                guard fileManager.fileExists(atPath: destinationURL.path) else { throw NSError(domain: "FileNotSaved", code: -1, userInfo: nil) }
                guard fileManager.isReadableFile(atPath: destinationURL.path) else { throw NSError(domain: "FileNotAccessible", code: -1, userInfo: nil) }
                
                log("File successfully saved and is accessible at: \(destinationURL.path)")
                
                // Handle the completion of the download on the main thread
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
        
        private let beginOfText = "<|begin_of_text|>"
        private let startHeaderId = "<|start_header_id|>"
        private let endHeaderId = "<|end_header_id|>"
        private let eotId = "<|eot_id|>"
        
        private var llamaContext: LlamaContext?
        private var isInitialHeatUp = true
        
        @Published var memoryUsage: Double = 0
        @Published var cpuUsage: Double = 0
        @Published var completionTime: TimeInterval = 0
        
        private let contextSizeLimit: Int32 = 2048 // This should match the model's context size
        private let stopTokens: Set<String> = ["User:", "Assistant:", "user:", "assistant:", "</s>", "Human:", "human:", "User", "Assistant", "Human"]
        private let maxNewLines = 3 // Maximum number of consecutive new lines

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
        
        func complete(messages: [LPChatMessage], onToken: @escaping (String) -> Void) async throws {
            guard let llamaContext = llamaContext else { throw LPChatError.contextNotInitialized }

            self.messages = messages

            let formattedPrompt: String
            do { formattedPrompt = try await formatPrompt() } catch { throw LPChatError.tokenizationFailed }

            log("Formatted prompt:\n\(formattedPrompt)")

            await llamaContext.completion_init(text: formattedPrompt)

            var assistantResponse = ""
            var tokenCount: Int32 = 0
            var newLineCount = 0
            var partialStopToken = ""

            let promptTokens = await llamaContext.get_n_tokens()
            let remainingTokens = max(0, contextSizeLimit - promptTokens)
            let maxTokens: Int32 = min(remainingTokens, 1000) // Limit to 1000 tokens or remaining context, whichever is smaller

            log("Starting token generation loop (remaining tokens: \(remainingTokens), max tokens: \(maxTokens))")

            while tokenCount < maxTokens {
                let result = await llamaContext.completion_loop()
                let trimmedResult = tokenCount == 0 ? result.trimmingCharacters(in: .whitespaces) : result
                log("Token generated: \(trimmedResult)")

                // Check for new lines
                if trimmedResult == "\n" {
                    newLineCount += 1
                } else {
                    newLineCount = 0
                }

                if newLineCount >= maxNewLines {
                    log("Max new lines reached, breaking loop")
                    break
                }

                // Check for stop sequences
                partialStopToken += trimmedResult
                if shouldStop(partialStopToken) {
                    log("Stop sequence detected")
                    break
                }
                
                // Reset partial stop token if it gets too long
                if partialStopToken.count > 20 { partialStopToken = String(partialStopToken.suffix(10)) }

                if !isPartOfStopSequence(trimmedResult) {
                    assistantResponse += trimmedResult
                    tokenCount += 1
                    onToken(trimmedResult)
                }

                if await llamaContext.n_cur % 10 == 0 { await updateMetrics() }
            }

            log("Token generation loop completed")

            // Clean up the response
            assistantResponse = cleanResponse(assistantResponse)
            log("Final assistant response: \(assistantResponse)")

            if !assistantResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if isResponseCoherent(assistantResponse) {
                    self.messages.append(LPChatMessage(role: .assistant, content: assistantResponse))
                } else {
                    let fixedResponse = tryToFixResponse(assistantResponse)
                    if !fixedResponse.isEmpty {
                        self.messages.append(LPChatMessage(role: .assistant, content: fixedResponse))
                    } else {
                        log("Discarded incoherent response")
                    }
                }
            }
        }
        
        // MARK: - Private Methods
        private func log(_ message: String) { if enableLogging { print("[Lightpack] \(message)") } }
        
        private func shouldStop(_ text: String) -> Bool {
                stopTokens.contains { text.lowercased().hasSuffix($0.lowercased()) }
            }

        private func isPartOfStopSequence(_ text: String) -> Bool {
            stopTokens.contains { text.lowercased().contains($0.lowercased()) }
        }
        
        private func cleanResponse(_ response: String) -> String {
            var cleaned = response.trimmingCharacters(in: .whitespacesAndNewlines)
            for stopToken in stopTokens {
                while cleaned.lowercased().hasSuffix(stopToken) {
                    if let range = cleaned.range(of: stopToken, options: [.caseInsensitive, .backwards]) {
                        cleaned = String(cleaned[..<range.lowerBound])
                    }
                    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            while cleaned.hasSuffix(":") {
                cleaned = String(cleaned.dropLast())
                cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return cleaned
        }
        
        private func isResponseCoherent(_ response: String) -> Bool {
            let minLength = 10
            let hasSentenceStructure = response.contains(where: { ".!?".contains($0) })
            return response.count >= minLength && hasSentenceStructure
        }
        
        private func tryToFixResponse(_ response: String) -> String {
            if let lastSentenceRange = response.range(of: "[^.!?]+[.!?]", options: [.regularExpression, .backwards]) {
                return String(response[response.startIndex...lastSentenceRange.upperBound])
            }
            return ""
        }
        
        private func formatPrompt() async throws -> String {
            var formattedMessages = messages.map { message -> String in
                switch message.role {
                case .system:
                    return message.content
                case .user:
                    return "User: \(message.content)"
                case .assistant:
                    return "Assistant: \(message.content)"
                }
            }
            
            let promptTemplate = """
            {CONVERSATION}
            Assistant:
            """
            
            let conversation = formattedMessages.joined(separator: "\n\n")
            var prompt = promptTemplate.replacingOccurrences(of: "{CONVERSATION}", with: conversation)
            
            // Check if the prompt exceeds the context size limit
            var tokens: [llama_token]
            do {
                tokens = try await tokenizeString(prompt)
            } catch {
                throw LPChatError.tokenizationFailed
            }
            
            while tokens.count > Int(contextSizeLimit) {
                if formattedMessages.count > 1 {
                    formattedMessages.removeFirst()
                    let updatedConversation = formattedMessages.joined(separator: "\n\n")
                    prompt = promptTemplate.replacingOccurrences(of: "{CONVERSATION}", with: updatedConversation)
                } else {
                    break // Can't remove more without losing the last exchange
                }
                
                do {
                    tokens = try await tokenizeString(prompt)
                } catch {
                    throw LPChatError.tokenizationFailed
                }
            }
            
            return prompt
        }
        
        private func tokenizeString(_ string: String) async throws -> [llama_token] {
            guard let llamaContext = llamaContext else { throw LPChatError.contextNotInitialized }
            return await llamaContext.tokenize(text: string, add_bos: true)
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
    
    actor LlamaContext {
        private var enableLogging: Bool = true
        private func log(_ message: String) { if enableLogging { print("[Lightpack] \(message)") } }
        
        private var model: OpaquePointer
        private var context: OpaquePointer
        private var batch: llama_batch
        private var tokens_list: [llama_token]
        var is_done: Bool = false

        /// This variable is used to store temporarily invalid cchars
        private var temporary_invalid_cchars: [CChar]

        var n_len: Int32 = 1024
        var n_cur: Int32 = 0

        var n_decode: Int32 = 0

        init(model: OpaquePointer, context: OpaquePointer, enableLogging: Bool = true) {
            self.model = model
            self.context = context
            self.tokens_list = []
            self.batch = llama_batch_init(512, 0, 1)
            self.temporary_invalid_cchars = []
            self.enableLogging = enableLogging
        }

        deinit {
            llama_batch_free(batch)
            llama_free(context)
            llama_free_model(model)
            llama_backend_free()
        }

        static func create_context(path: String) throws -> LlamaContext {
            llama_backend_init()
            var model_params = llama_model_default_params()

    #if targetEnvironment(simulator)
            model_params.n_gpu_layers = 0
//            log("Running on simulator, force use n_gpu_layers = 0")
    #endif
            let model = llama_load_model_from_file(path, model_params)
            guard let model else { throw LPLlamaError.couldNotInitializeContext }

            let n_threads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))

            var ctx_params = llama_context_default_params()
            ctx_params.seed  = 1234
            ctx_params.n_ctx = 2048
            ctx_params.n_threads       = UInt32(n_threads)
            ctx_params.n_threads_batch = UInt32(n_threads)

            let context = llama_new_context_with_model(model, ctx_params)
            guard let context else { throw LPLlamaError.couldNotInitializeContext }

            return LlamaContext(model: model, context: context)
        }

        func model_info() -> String {
            let result = UnsafeMutablePointer<Int8>.allocate(capacity: 256)
            result.initialize(repeating: Int8(0), count: 256)
            defer { result.deallocate() }

            // TODO: there is probably another way to get the string from C

            let nChars = llama_model_desc(model, result, 256)
            let bufferPointer = UnsafeBufferPointer(start: result, count: Int(nChars))

            var SwiftString = ""
            for char in bufferPointer { SwiftString.append(Character(UnicodeScalar(UInt8(char)))) }

            return SwiftString
        }

        func get_n_tokens() -> Int32 { return batch.n_tokens }
        
        func completion_init(text: String) {
            log("attempting to complete \"\(text)\"")

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

        func completion_loop() -> String {
            var new_token_id: llama_token = 0

            let n_vocab = llama_n_vocab(model)
            let logits = llama_get_logits_ith(context, batch.n_tokens - 1)

            var candidates = Array<llama_token_data>()
            candidates.reserveCapacity(Int(n_vocab))

            for token_id in 0..<n_vocab {
                candidates.append(llama_token_data(id: token_id, logit: logits![Int(token_id)], p: 0.0))
            }
            candidates.withUnsafeMutableBufferPointer() { buffer in
                var candidates_p = llama_token_data_array(data: buffer.baseAddress, size: buffer.count, sorted: false)
                new_token_id = llama_sample_token_greedy(context, &candidates_p)
            }

            if llama_token_is_eog(model, new_token_id) || n_cur == n_len {
                is_done = true
                let new_token_str = String(cString: temporary_invalid_cchars + [0])
                temporary_invalid_cchars.removeAll()
                return new_token_str
            }

            let new_token_cchars = token_to_piece(token: new_token_id)
            temporary_invalid_cchars.append(contentsOf: new_token_cchars)
            let new_token_str: String
            if let string = String(validatingUTF8: temporary_invalid_cchars + [0]) {
                temporary_invalid_cchars.removeAll()
                new_token_str = string
            } else if (0 ..< temporary_invalid_cchars.count).contains(where: {$0 != 0 && String(validatingUTF8: Array(temporary_invalid_cchars.suffix($0)) + [0]) != nil}) {
                // in this case, at least the suffix of the temporary_invalid_cchars can be interpreted as UTF8 string
                let string = String(cString: temporary_invalid_cchars + [0])
                temporary_invalid_cchars.removeAll()
                new_token_str = string
            } else {
                new_token_str = ""
            }
            // tokens_list.append(new_token_id)

            llama_batch_clear(&batch)
            llama_batch_add(&batch, new_token_id, n_cur, [0], true)

            n_decode += 1
            n_cur    += 1

            if llama_decode(context, batch) != 0 { log("failed to evaluate llama!") }

            return new_token_str
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
            let backend        = "Metal";
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
