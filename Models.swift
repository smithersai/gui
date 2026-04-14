import SwiftUI

struct ChatSession: Identifiable, Hashable {
    let id: String
    let title: String
    let preview: String
    let timestamp: String
    let group: String
}

struct ChatMessage: Identifiable {
    let id: String
    let type: MessageType
    let content: String
    let timestamp: String
    let command: Command?
    let diff: Diff?
    
    enum MessageType: String {
        case user, assistant, command, diff, status
    }
}

struct Command {
    let cmd: String
    let cwd: String
    let output: String
    let exitCode: Int
    let running: Bool?
}

struct Diff {
    let files: [DiffFile]
    let totalAdditions: Int
    let totalDeletions: Int
    let status: String
    let snippet: String
}

struct DiffFile {
    let name: String
    let additions: Int
    let deletions: Int
}

struct Agent: Identifiable {
    let id: String
    let name: String
    let status: AgentStatus
    let task: String
    let changes: Int
    
    enum AgentStatus: String {
        case idle, working, completed, failed
    }
}

struct JJChange: Identifiable {
    var id: String { file }
    let file: String
    let status: String
    let additions: Int
    let deletions: Int
}

// MARK: - Mock Data

let mockSessions: [ChatSession] = [
    ChatSession(id: "1", title: "Refactor auth middleware", preview: "Can you help me refactor the authentication middleware to use the new JWT library?", timestamp: "2m ago", group: "Today"),
    ChatSession(id: "2", title: "Fix memory leak in WebSocket", preview: "There's a memory leak when clients disconnect from the WebSocket server...", timestamp: "1h ago", group: "Today"),
    ChatSession(id: "3", title: "Add dark mode toggle", preview: "I need to implement a dark mode toggle using CSS custom properties...", timestamp: "3h ago", group: "Today"),
    ChatSession(id: "4", title: "Database migration script", preview: "Write a migration script to add the new user_preferences table with...", timestamp: "Yesterday", group: "Yesterday"),
    ChatSession(id: "5", title: "Optimize image pipeline", preview: "The image processing pipeline is too slow, need to add caching...", timestamp: "Yesterday", group: "Yesterday"),
    ChatSession(id: "6", title: "Setup CI/CD pipeline", preview: "Help me configure GitHub Actions for automated testing and deployment...", timestamp: "Mon", group: "This Week"),
    ChatSession(id: "7", title: "GraphQL schema design", preview: "Design a GraphQL schema for the e-commerce product catalog...", timestamp: "Sun", group: "This Week"),
    ChatSession(id: "8", title: "Redis caching layer", preview: "Implement a Redis caching layer for the API responses...", timestamp: "Feb 1", group: "Older")
]

let mockMessages: [ChatMessage] = [
    ChatMessage(id: "m1", type: .user, content: "Can you help me refactor the authentication middleware to use the new JWT library? The current implementation is using jsonwebtoken but I want to switch to jose.", timestamp: "2:34 PM", command: nil, diff: nil),
    ChatMessage(id: "m2", type: .assistant, content: "I'll help you refactor the auth middleware from `jsonwebtoken` to `jose`. The `jose` library is more modern, has better TypeScript support, and works in edge runtimes.\n\nLet me first look at your current implementation to understand the structure.", timestamp: "2:34 PM", command: nil, diff: nil),
    ChatMessage(id: "m3", type: .command, content: "", timestamp: "2:34 PM", command: Command(cmd: "cat src/middleware/auth.ts", cwd: "~/projects/web-app", output: "import jwt from 'jsonwebtoken';\nimport { Request, Response, NextFunction } from 'express';\n\nconst SECRET = process.env.JWT_SECRET!;\n\nexport function authMiddleware(req: Request, res: Response, next: NextFunction) {\n  const token = req.headers.authorization?.split(' ')[1];\n  if (!token) return res.status(401).json({ error: 'No token' });\n  try {\n    const decoded = jwt.verify(token, SECRET);\n    req.user = decoded;\n    next();\n  } catch {\n    res.status(401).json({ error: 'Invalid token' });\n  }\n}", exitCode: 0, running: false), diff: nil),
    ChatMessage(id: "m4", type: .assistant, content: "I can see the current middleware. Here's my plan:\n\n1. Replace `jsonwebtoken` import with `jose`\n2. Switch from synchronous `jwt.verify()` to async `jwtVerify()`\n3. Add proper type safety for the JWT payload\n4. Make the middleware async-compatible\n\nLet me apply the changes now.", timestamp: "2:35 PM", command: nil, diff: nil),
    ChatMessage(id: "m10", type: .assistant, content: "All 4 tests pass. The refactoring from `jsonwebtoken` to `jose` is fully verified and working correctly.", timestamp: "2:36 PM", command: nil, diff: nil)
]
