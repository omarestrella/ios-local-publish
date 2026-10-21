import Foundation
import Observation

@MainActor @Observable
final class Discovery: NSObject, @preconcurrency NetServiceBrowserDelegate, @preconcurrency NetServiceDelegate {
    private(set) var publishers: [Publisher] = []
    private var browser: NetServiceBrowser?
    private var services: [NetService] = []

    func start() {
        guard browser == nil else { return }
        let browser = NetServiceBrowser()
        browser.delegate = self
        self.browser = browser
        browser.searchForServices(ofType: "_ios-publish._tcp.", inDomain: "local.")
    }

    func stop() {
        browser?.stop()
        browser = nil
        services.forEach { $0.stop() }
        services.removeAll()
        publishers.removeAll()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        services.append(service)
        service.delegate = self
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeAll { $0 == service }
        publishers.removeAll { $0.name == service.name }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let data = sender.txtRecordData(),
              let urlData = NetService.dictionary(fromTXTRecord: data)["url"],
              let string = String(data: urlData, encoding: .utf8),
              let url = URL(string: string), PublisherClient.validURL(url) else { return }
        if !publishers.contains(where: { $0.url == url }) {
            publishers.append(Publisher(name: sender.name, url: url))
        }
    }
}
