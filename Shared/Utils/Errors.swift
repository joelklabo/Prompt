import Foundation

enum PromptError: LocalizedError, Sendable {
    case notFound(UUID)
    case invalidContent(reason: String)
    case syncConflict(localID: UUID, remoteID: UUID)
    case quotaExceeded(limit: Int)
    case invalidRequest
    case invalidCategory(String)
    case tagNotFound(UUID)

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Prompt with ID \(id) not found"
        case .invalidContent(let reason):
            return "Invalid prompt content: \(reason)"
        case .syncConflict:
            return "Sync conflict detected"
        case .quotaExceeded(let limit):
            return "Prompt limit exceeded (max: \(limit))"
        case .invalidRequest:
            return "Invalid request parameters"
        case .invalidCategory(let category):
            return "Invalid category: \(category)"
        case .tagNotFound(let id):
            return "Tag with ID \(id) not found"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notFound:
            return "The prompt may have been deleted"
        case .invalidContent:
            return "Please check the prompt content and try again"
        case .syncConflict:
            return "Choose which version to keep"
        case .quotaExceeded:
            return "Delete some prompts or upgrade your plan"
        case .invalidRequest:
            return "Please provide valid request parameters"
        case .invalidCategory:
            return "Choose from: Prompts, Configs, Commands, or Context"
        case .tagNotFound:
            return "The tag may have been deleted"
        }
    }
}

enum TagError: LocalizedError, Sendable {
    case notFound(UUID)
    case invalidRequest
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let id):
            return "Tag with ID \(id) not found"
        case .invalidRequest:
            return "Invalid request parameters"
        case .duplicateName(let name):
            return "Tag with name '\(name)' already exists"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notFound:
            return "The tag may have been deleted"
        case .invalidRequest:
            return "Please provide valid request parameters"
        case .duplicateName:
            return "Choose a different tag name"
        }
    }
}

enum AIError: LocalizedError {
    case modelUnavailable
    case analysisTimeout
    case invalidResponse(String)
    case rateLimited(retryAfter: TimeInterval)

    var errorDescription: String? {
        switch self {
        case .modelUnavailable:
            return "AI features are temporarily unavailable"
        case .analysisTimeout:
            return "Analysis took too long to complete"
        case .invalidResponse(let detail):
            return "Invalid AI response: \(detail)"
        case .rateLimited(let seconds):
            return "Too many requests. Try again in \(Int(seconds)) seconds"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .modelUnavailable:
            return "Please try again later"
        case .analysisTimeout:
            return "Try with a shorter prompt"
        case .invalidResponse:
            return "Contact support if this persists"
        case .rateLimited:
            return "Please wait before trying again"
        }
    }
}

enum SyncError: LocalizedError {
    case cloudKitNotAvailable
    case networkError(Error)
    case authenticationRequired
    case quotaExceeded

    var errorDescription: String? {
        switch self {
        case .cloudKitNotAvailable:
            return "iCloud sync is not available"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .authenticationRequired:
            return "Please sign in to iCloud"
        case .quotaExceeded:
            return "iCloud storage quota exceeded"
        }
    }
}
