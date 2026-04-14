//
//  ProviderManaging.swift
//  AgentNotch
//
//  Protocol that every LLM provider manager must conform to.
//  Allows ProviderRegistry to treat all providers uniformly.
//

import Foundation
import Combine

protocol ProviderManaging: AnyObject {
    var provider: LLMProvider { get }

    /// Emits a new ProviderUsage snapshot whenever fresh data is available
    var usagePublisher: AnyPublisher<ProviderUsage, Never> { get }

    /// Emits connection state changes
    var connectionStatePublisher: AnyPublisher<ProviderConnectionState, Never> { get }

    /// Trigger an immediate data refresh
    func refresh() async

    /// Start periodic polling
    func startPolling()

    /// Stop periodic polling
    func stopPolling()
}
