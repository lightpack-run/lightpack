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
    case validationError(message: String)
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
    public var alias: String
    public let bits: Double
    public var downloadProgress: Double = 0
    private var _downloadUrl: String?
    public let familyId: String
    public let modelId: String
    public let parameterId: String
    public let quantizationId: String
    public let size: Double
    public let specialTokens: String
    public let template: String
    public var status: LPModelStatus = .notDownloaded
    public let title: String
    public let updatedAt: String
    
    var downloadUrl: String? {
        get { _downloadUrl }
        set { _downloadUrl = newValue }
    }

    enum CodingKeys: String, CodingKey {
        case alias, bits, familyId, modelId, parameterId, quantizationId, size, specialTokens, template, title, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        alias = try container.decode(String.self, forKey: .alias)
        bits = try container.decode(Double.self, forKey: .bits)
        familyId = try container.decode(String.self, forKey: .familyId)
        modelId = try container.decode(String.self, forKey: .modelId)
        parameterId = try container.decode(String.self, forKey: .parameterId)
        quantizationId = try container.decode(String.self, forKey: .quantizationId)
        size = try container.decode(Double.self, forKey: .size)
        specialTokens = try container.decode(String.self, forKey: .specialTokens)
        template = try container.decode(String.self, forKey: .template)
        title = try container.decode(String.self, forKey: .title)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
    }
}

public struct LPModelFamily: Codable {
    public let familyId: String
    public let alias: String
    public let author: String
    public let defaultAliasIds: [DefaultAliasId]
    public let defaultModelId: String
    public let gitHub: String
    public let huggingFace: String
    public let image: String
    public let license: String
    public let paper: String
    public let title: String
    public let updatedAt: String

    public struct DefaultAliasId: Codable {
        public let parameterId: String
        public let defaultQuantizationId: String
    }

    enum CodingKeys: String, CodingKey {
        case familyId, alias, author, defaultAliasIds, defaultModelId, gitHub, huggingFace, image, license, paper, title, updatedAt
    }
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
    case cancelDownloadingModel = "cancelDownloadingModel"
    case chatModel = "chatModel"
    case downloadModel = "downloadModel"
    case getModelDownload = "getModelDownload"
    case getModelFamilies = "getModelFamilies"
    case getModels = "getModels"
    case loadModel = "loadModel"
    case packageError = "packageError"
    case pauseDownloadingModel = "pauseDownloadingModel"
    case postEvent = "postEvent"
    case removeModels = "removeModels"
    case resumeDownloadingModel = "resumeDownloadingModel"
}

enum LPChatError: Error {
    case completionFailed,
         contextNotInitialized,
         modelNotSet,
         promptFormattingFailed,
         noModelId,
         tokenizationFailed,
         unknownError
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
    case assistant, system, tool, user
}

public struct LPChatMessage: Codable, Equatable, Identifiable {
    public let id: UUID
    public let role: LPMessageType
    public var content: String
    
    public init(role: LPMessageType, content: String) {
        self.id = UUID()
        self.role = role
        self.content = content
    }
    
    enum CodingKeys: String, CodingKey {
        case id, role, content
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        role = try container.decode(LPMessageType.self, forKey: .role)
        content = try container.decode(String.self, forKey: .content)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(role, forKey: .role)
        try container.encode(content, forKey: .content)
    }
}
