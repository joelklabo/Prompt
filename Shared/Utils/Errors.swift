import Foundation

enum PromptError: LocalizedError {
    case notFound(UUID)
    case invalidContent(reason: String)
    case syncConflict(local: Prompt, remote: Prompt)
    case quotaExceeded(limit: Int)

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
