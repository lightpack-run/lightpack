import Foundation

public enum LPDownloadError: Error {
    case notPaused, noTaskFound, fileMissing, fileNotSaved, fileNotAccessible, noDownloadUrl
}

public enum LPError: Error {
    case apiError(String)
    case decodingError(Error)
    case downloadError(LPDownloadError)
    case endpointConstruction
    case encodingError(Error)
    case invalidInput(String)
    case invalidResponse
    case modelNotFound
    case modelIsEmpty
    case networkError(Error)
    case noData
    case unknownError(String)
}

public struct LPErrorResponse: Codable {
    public let error: String
}

public struct LPModelsResponse: Codable {
    public let models: [LPModel]
    public let page: Int
    public let pageSize: Int
    public let total: Int
}

public struct LPModelFamiliesResponse: Codable {
    public let modelFamilies: [LPModelFamily]
    public let page: Int
    public let pageSize: Int
    public let total: Int
}

public struct LPModelMetadataResponse: Codable {
    let familyModels: [String: LPModelFamily]
    let models: [String: LPModel]
    let updatedAt: String?
}

public enum LPModelStatus: String, Codable, Equatable, Hashable {
    case downloading, downloaded, notDownloaded, outdated, paused
}

public enum LPModelFileTypes: String, Codable {
    case gguf
}

public struct LPModel: Identifiable, Equatable, Codable {
    public var id: String { modelId }
    public let bits: Double
    public var downloadProgress: Double = 0
    private var _downloadUrl: String?
    public let familyId: String
    public let modelId: String
    public let parameterId: String
    public let quantizationId: String
    public let size: Double
    public var status: LPModelStatus = .notDownloaded
    public let title: String
    public let updatedAt: String
    
    var downloadUrl: String? {
        get { _downloadUrl }
        set { _downloadUrl = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case bits, familyId, modelId, parameterId, quantizationId, size, title, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bits = try container.decode(Double.self, forKey: .bits)
        familyId = try container.decode(String.self, forKey: .familyId)
        modelId = try container.decode(String.self, forKey: .modelId)
        parameterId = try container.decode(String.self, forKey: .parameterId)
        quantizationId = try container.decode(String.self, forKey: .quantizationId)
        size = try container.decode(Double.self, forKey: .size)
        title = try container.decode(String.self, forKey: .title)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }
}

public struct LPModelFamily: Codable {
    public let familyId: String
    public let modelParameterIds: [String]
    public let title: String
    public let updatedAt: String
}

public struct LPModelDownloadResponse: Codable {
    public let downloadUrl: String
}

public struct LPClientInfo {
    let appBuild: String?
    let appBundleId: String?
    let appVersion: String?
    let deviceAvailableStorage: Int64?
    let deviceId: String
    let deviceLocale: String
    let deviceModel: String
    let deviceOS: String
    let deviceOSVersion: String
    let devicePreferredLanguage: String?
    let deviceTimeZone: String
    let deviceTotalStorage: Int?
    let packageVersion: String
}

public struct LPPostEventResponse: Codable {
    public let success: Bool
}

public enum LPApiType: String {
    case clearChat = "clearChat"
    case cancelDownloadModel = "cancelDownloadModel"
    case chatModel = "chatModel"
    case downloadModel = "downloadModel"
    case getModelDownload = "getModelDownload"
    case getModelFamilies = "getModelFamilies"
    case getModels = "getModels"
    case loadModel = "loadModel"
    case packageError = "packageError"
    case pauseDownloadModel = "pauseDownloadModel"
    case postEvent = "postEvent"
    case removeModels = "removeModels"
    case resumeDownloadModel = "resumeDownloadModel"
}

enum LPChatError: Error {
    case noModelId, contextNotInitialized, tokenizationFailed, completionFailed, unknownError
}

public enum LPLlamaError: Error {
    case couldNotInitializeContext
    case fileNotFound
    case filePermissionDenied
    case insufficientMemory
    case incompatibleModelFormat
    case modelLoadError(String)
    case contextCreationError(String)
}

public enum LPMessageType: String, Codable, Equatable {
    case assistant, system, user
}

public struct LPChatMessage: Codable, Equatable {
    public let role: LPMessageType
    public var content: String
    
    public init(role: LPMessageType, content: String) {
        self.role = role
        self.content = content
    }
    
    enum CodingKeys: String, CodingKey {
        case role, content
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decode(LPMessageType.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
    }
}
