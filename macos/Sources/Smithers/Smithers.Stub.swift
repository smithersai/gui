#if SMITHERS_STUB
import Foundation

extension Smithers {
    enum Stub {
        static func responseData(method: String) -> Data {
            let listMethods = [
                "listWorkflows", "listRuns", "listAgents", "listMemoryFacts",
                "listAllMemoryFacts", "recallMemory", "listRecentScores",
                "listTickets", "searchTickets", "listPrompts", "listSnapshots",
                "listJJHubWorkflows", "listChanges", "listSQLTables", "listCrons",
                "listPendingApprovals", "listRecentDecisions", "listLandings",
                "listIssues", "listWorkspaces", "listWorkspaceSnapshots", "search",
            ]
            if listMethods.contains(method) {
                return Data("[]".utf8)
            }

            switch method {
            case "getWorkflowDAG":
                return Data("""
                {"workflowID":null,"mode":null,"runId":null,"frameNo":null,"xml":null,"tasks":[],"graphEdges":null,"entryTask":null,"entryTaskID":null,"fields":null,"message":null}
                """.utf8)
            case "runWorkflow":
                return Data(#"{"runId":"stub-run"}"#.utf8)
            case "inspectRun":
                return Data("""
                {"run":{"runId":"stub-run","workflowName":null,"workflowPath":null,"status":"unknown","startedAtMs":null,"finishedAtMs":null,"summary":null,"errorJson":null},"tasks":[]}
                """.utf8)
            case "getDevToolsSnapshot":
                return Data(#"{"runId":"stub-run","frameNo":0,"seq":0,"root":{"id":0,"type":"workflow","name":"Workflow","props":{},"task":null,"children":[],"depth":0}}"#.utf8)
            case "jumpToFrame":
                return Data(#"{"ok":true,"newFrameNo":0,"revertedSandboxes":0,"deletedFrames":0,"deletedAttempts":0,"invalidatedDiffs":0,"durationMs":0}"#.utf8)
            case "getNodeOutput":
                return Data(#"{"status":"pending","row":null,"schema":null,"partial":null}"#.utf8)
            case "getNodeDiff":
                return Data(#"{"seq":0,"baseRef":"","patches":[]}"#.utf8)
            case "getOrchestratorVersion":
                return Data(#""0.16.0""#.utf8)
            case "status", "changeDiff", "workingCopyDiff", "landingDiff", "landingChecks", "previewPrompt", "readWorkflowSource", "rerunRun":
                return Data(#""""#.utf8)
            case "hasSmithersProject":
                return Data("false".utf8)
            case "hijackRun":
                return Data(#"{"runId":"stub-run","agentEngine":"smithers","agentBinary":"smithers","resumeToken":"","cwd":"/tmp","supportsResume":false,"launchCommand":null,"launchArgs":[],"mode":null,"resumeCommand":null}"#.utf8)
            default:
                return Data("{}".utf8)
            }
        }
    }
}
#endif
