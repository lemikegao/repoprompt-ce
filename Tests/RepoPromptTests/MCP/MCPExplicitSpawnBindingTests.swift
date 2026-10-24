import Foundation
@testable import RepoPromptApp
import RepoPromptSettingsCore
import XCTest

final class MCPExplicitSpawnBindingTests: XCTestCase {
    @MainActor
    func testAgentRunSpawnRebindPreservesExplicitBindContextPin() async throws {
        let previousAutoStart = GlobalSettingsStore.shared.mcpAutoStart()
        GlobalSettingsStore.shared.setMCPAutoStart(false, commit: false)
        let window = WindowState()
        WindowStatesManager.shared.registerWindowState(window)
        GlobalSettingsStore.shared.setMCPAutoStart(previousAutoStart, commit: false)
        defer { WindowStatesManager.shared.unregisterWindowState(window) }

        let workspaceID = UUID()
        let pinnedTabID = UUID()
        let agentTabID = UUID()
        let workspace = WorkspaceModel(
            id: workspaceID,
            name: "Spawn Rebind Seniority",
            repoPaths: [],
            ephemeralFlag: true,
            composeTabs: [
                ComposeTabState(id: pinnedTabID, name: "Pinned"),
                ComposeTabState(id: agentTabID, name: "Agent Session")
            ],
            activeComposeTabID: pinnedTabID
        )
        window.workspaceManager.workspaces = [workspace]
        await window.workspaceManager.switchWorkspace(
            to: workspace,
            saveState: false,
            reason: "agentRunSpawnRebindSeniorityTest"
        )

        // An explicit bind_context pin to a different tab survives the spawn rebind.
        let explicitConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: explicitConnectionID,
            clientName: "external-explicit-client",
            tabID: pinnedTabID,
            workspaceID: workspaceID,
            windowID: window.windowID
        )
        try await window.mcpServer.bindCurrentRequestToTabIfPossible(
            tabID: agentTabID,
            metadata: MCPServerViewModel.RequestMetadata(
                connectionID: explicitConnectionID,
                clientName: "external-explicit-client",
                windowID: window.windowID
            )
        )
        let preserved = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[explicitConnectionID])
        XCTAssertEqual(preserved.tabID, pinnedTabID)
        XCTAssertTrue(preserved.explicitlyBound)

        // An implicit (window-affinity) binding still follows the spawn to the session tab.
        let implicitConnectionID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: implicitConnectionID,
            clientName: "external-implicit-client",
            tabID: pinnedTabID,
            workspaceID: workspaceID,
            windowID: window.windowID,
            explicitlyBound: false
        )
        try await window.mcpServer.bindCurrentRequestToTabIfPossible(
            tabID: agentTabID,
            metadata: MCPServerViewModel.RequestMetadata(
                connectionID: implicitConnectionID,
                clientName: "external-implicit-client",
                windowID: window.windowID
            )
        )
        let followed = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[implicitConnectionID])
        XCTAssertEqual(followed.tabID, agentTabID)

        // An .agentModeRun caller's run-scoped source binding is still preserved.
        let agentRunConnectionID = UUID()
        let sourceRunID = UUID()
        try window.mcpServer.bindTabForConnection(
            connectionID: agentRunConnectionID,
            clientName: "agent",
            tabID: pinnedTabID,
            workspaceID: workspaceID,
            windowID: window.windowID,
            runID: sourceRunID,
            explicitlyBound: false
        )
        await ServerNetworkManager.shared.setRunPurpose(.agentModeRun, for: agentRunConnectionID)
        addTeardownBlock {
            await ServerNetworkManager.shared.setRunPurpose(.unknown, for: agentRunConnectionID)
        }
        try await window.mcpServer.bindCurrentRequestToTabIfPossible(
            tabID: agentTabID,
            metadata: MCPServerViewModel.RequestMetadata(
                connectionID: agentRunConnectionID,
                clientName: "agent",
                windowID: window.windowID
            )
        )
        let sourcePreserved = try XCTUnwrap(window.mcpServer.tabContextByConnectionID[agentRunConnectionID])
        XCTAssertEqual(sourcePreserved.tabID, pinnedTabID)
        XCTAssertFalse(sourcePreserved.explicitlyBound)
    }
}
