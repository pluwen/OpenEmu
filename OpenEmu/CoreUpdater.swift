// Copyright (c) 2021, OpenEmu Team
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
//     * Redistributions of source code must retain the above copyright
//       notice, this list of conditions and the following disclaimer.
//     * Redistributions in binary form must reproduce the above copyright
//       notice, this list of conditions and the following disclaimer in the
//       documentation and/or other materials provided with the distribution.
//     * Neither the name of the OpenEmu Team nor the
//       names of its contributors may be used to endorse or promote products
//       derived from this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY OpenEmu Team ''AS IS'' AND ANY
// EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL OpenEmu Team BE LIABLE FOR ANY
// DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
// ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
// SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import Foundation
import OpenEmuKit
import Sparkle.SUStandardVersionComparator

final class CoreUpdater: NSObject {
    
    enum Errors: Error {
        case noDownloadableCoreForIdentifierError
        case newCoreCheckAlreadyPendingError
    }
    
    private static let coreListURL = URL(string: "https://raw.githubusercontent.com/OpenEmu/OpenEmu-Update/master/cores.json")!
    
    static let shared = CoreUpdater()
    
    @objc dynamic private(set) var coreList: [CoreDownload] = []
    
    private var completionHandler: ((_ plugin: OECorePlugin?, Error?) -> Void)?
    private var coreIdentifier: String?
    private var alert: OEAlert?
    private var coreDownload: CoreDownload?
    
    private var coresDict: [String : CoreDownload] = [:]
    private var coreListURLTask: URLSessionDataTask?
    private var pendingUserInitiatedDownloads: Set<CoreDownload> = []
    private var cores: [Core]?
    
    private override init() {
        super.init()
        
        for plugin in OECorePlugin.allPlugins {
            let download = CoreDownload(plugin: plugin)
            let bundleID = plugin.bundleIdentifier.lowercased()
            coresDict[bundleID] = download
        }
        
        updateCoreList()
    }
    
    private func updateCoreList() {
        willChangeValue(forKey: #keyPath(coreList))
        coreList = coresDict.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        didChangeValue(forKey: #keyPath(coreList))
    }
    
    func checkForUpdates(andInstall autoInstall: Bool = false, reloadData: Bool = false, completionHandler handler: ((_ error: Error?) -> Void)? = nil) {
        if cores == nil || reloadData {
            DispatchQueue.main.async {
                self.downloadCoreList { error in
                    self.checkInstalledCoresForUpdates(andInstall: autoInstall)
                    self.checkForNewCores()
                    handler?(error)
                }
            }
        } else {
            checkInstalledCoresForUpdates(andInstall: autoInstall)
            checkForNewCores()
            handler?(nil)
        }
    }
    
    private func checkInstalledCoresForUpdates(andInstall autoInstall: Bool) {
        guard let cores = cores else { return }
        
        for corePlugin in OECorePlugin.allPlugins {
            let corePluginID = corePlugin.bundleIdentifier.lowercased()
            if let download = coresDict[corePluginID],
               let core = cores.first(where: { $0.id == corePluginID }) {
                for release in core.releases {
                    if SUStandardVersionComparator.default.compareVersion(release.version, toVersion: corePlugin.version) == .orderedDescending,
                       release.isSupported
                    {
                        download.hasUpdate = true
                        download.url = URL(string: release.url)
                        download.sha256 = release.sha256
                        download.delegate = self
                        
                        if autoInstall {
                            download.start()
                        }
                        
                        continue
                    }
                }
            }
        }
        
        updateCoreList()
    }
    
    private func checkForNewCores() {
        guard let cores = cores else { return }
        
        for core in cores {
            guard coresDict[core.id] == nil else { continue }
            
            if core.isDeprecated {
                continue
            }
            
            if core.isExperimental,
               Bundle.main.infoDictionary!["OEExperimental"] as? Bool != true {
                continue
            }
            
            guard let release = core.latestSupportedRelease else {
                continue
            }
            
            let download = CoreDownload()
            download.name = core.name
            download.bundleIdentifier = core.id
            
            var systemIdentifiers: [String] = []
            var systemNames: [String] = []
            
            for system in core.systems {
                systemIdentifiers.append(system)
            }
            
            for systemIdentifier in systemIdentifiers {
                if let plugin = OESystemPlugin.systemPlugin(forIdentifier: systemIdentifier) {
                    systemNames.append(plugin.systemName)
                }
            }
            
            download.systemNames = systemNames
            download.systemIdentifiers = systemIdentifiers
            download.canBeInstalled = true
            
            download.url = URL(string: release.url)
            download.sha256 = release.sha256
            download.delegate = self
            
            if download == coreDownload {
                download.start()
            }
            
            coresDict[core.id] = download
        }
        
        updateCoreList()
    }
    
    private func downloadCoreList(completionHandler handler: ((_ error: Error?) -> Void)? = nil) {
        guard coreListURLTask == nil else {
            handler?(Errors.newCoreCheckAlreadyPendingError)
            return
        }
        
        let request = URLRequest(url: Self.coreListURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        coreListURLTask = URLSession.shared.dataTask(with: request) { data, response, error in
            DispatchQueue.main.async {
                guard let data = data,
                      let cores = try? JSONDecoder().decode([Core].self, from: data)
                else {
                    handler?(error)
                    self.coreListURLTask = nil
                    return
                }
                
                self.cores = cores
                
                handler?(nil)
                self.coreListURLTask = nil
            }
        }
        
        coreListURLTask?.resume()
    }
    
    func cancelCoreListDownload() {
        coreListURLTask?.cancel()
        coreListURLTask = nil
    }
    
    // MARK: - Installing with OEAlert
    
    func installCore(for game: OEDBGame, withCompletionHandler handler: @escaping (_ plugin: OECorePlugin?, _ error: Error?) -> Void) {
        
        let systemIdentifier = game.system?.systemIdentifier ?? ""
        var validPlugins = coreList.filter { $0.systemIdentifiers.contains(systemIdentifier) }
        
        if !validPlugins.isEmpty {
            let download: CoreDownload
            
            if validPlugins.count == 1 {
                download = validPlugins.first!
            } else {
                // Sort by core name alphabetically to match our automatic core picker behavior
                validPlugins.sort {
                    $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
                
                // Check if a core is set as default in AppDelegate
                var didFindDefaultCore = false
                var foundDefaultCoreIndex = 0
                
                for (index, plugin) in validPlugins.enumerated() {
                    let sysID = "defaultCore.\(systemIdentifier)"
                    if let userDef = UserDefaults.standard.string(forKey: sysID),
                       userDef.caseInsensitiveCompare(plugin.bundleIdentifier) == .orderedSame {
                        didFindDefaultCore = true
                        foundDefaultCoreIndex = index
                        break
                    }
                }
                
                // Use default core plugin for this system, otherwise just use first found from the sorted list
                if didFindDefaultCore {
                    download = validPlugins[foundDefaultCoreIndex]
                } else {
                    download = validPlugins.first!
                }
            }
            
            let coreName = download.name
            let message = String(format: NSLocalizedString("OpenEmu uses 'Cores' to emulate games. You need the %@ Core to play %@", comment: ""), coreName, game.displayName)
            installCore(with: download, message: message, completionHandler: handler)
        }
        else {
            handler(nil, Errors.noDownloadableCoreForIdentifierError)
        }
    }
    
    func installCore(for state: OEDBSaveState, withCompletionHandler handler: @escaping (_ plugin: OECorePlugin?, _ error: Error?) -> Void) {
        
        let coreID = state.coreIdentifier.lowercased()
        if let download = coresDict[coreID] {
            let coreName = download.name
            let message = String(format: NSLocalizedString("To launch the save state %@ you will need to install the '%@' Core", comment: ""), state.displayName, coreName)
            installCore(with: download, message: message, completionHandler: handler)
        } else {
            // TODO: create proper error saying that no core is available for the state
            handler(nil, Errors.noDownloadableCoreForIdentifierError)
        }
    }
    
    func installCore(with download: CoreDownload, message: String, completionHandler handler: @escaping (_ plugin: OECorePlugin?, _ error: Error?) -> Void) {
        
        let alert = OEAlert()
        alert.messageText = NSLocalizedString("Missing Core", comment: "")
        alert.informativeText = message
        alert.defaultButtonTitle = NSLocalizedString("Install", comment: "")
        alert.alternateButtonTitle = NSLocalizedString("Cancel", comment: "")
        alert.setDefaultButtonAction(#selector(startInstall), andTarget: self)
        
        coreIdentifier = coresDict.first(where: { $1 == download })?.key
        completionHandler = handler
        
        self.alert = alert
        
        if alert.runModal() == .alertSecondButtonReturn {
            handler(nil, NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        
        completionHandler = nil
        coreDownload = nil
        coreIdentifier = nil
        
        self.alert = nil
    }
    
    func installCore(with download: CoreDownload, completionHandler handler: @escaping (_ plugin: OECorePlugin?, _ error: Error?) -> Void) {
        
        let alert = OEAlert()
        
        coreIdentifier = coresDict.first(where: { $1 == download })?.key
        completionHandler = handler
        self.alert = alert
        
        alert.performBlockInModalSession {
            self.startInstall()
        }
        alert.runModal()
        
        completionHandler = nil
        coreDownload = nil
        coreIdentifier = nil
        
        self.alert = nil
    }
    
    // MARK: -
    
    @objc func cancelInstall() {
        coreDownload?.cancel()
        completionHandler = nil
        coreDownload = nil
        alert?.close(withResult: .alertSecondButtonReturn)
        alert = nil
        coreIdentifier = nil
    }
    
    @objc func startInstall() {
        alert?.messageText = NSLocalizedString("Downloading and Installing Core…", comment: "")
        alert?.informativeText = ""
        alert?.defaultButtonTitle = ""
        alert?.setAlternateButtonAction(#selector(cancelInstall), andTarget: self)
        alert?.showsProgressbar = true
        alert?.progress = 0
        
        guard
            let coreID = coreIdentifier,
            let pluginDL = coresDict[coreID]
        else {
            alert?.messageText = NSLocalizedString("Error!", comment: "")
            alert?.informativeText = NSLocalizedString("The core could not be downloaded. Try installing it from the Cores preferences.", comment: "")
            alert?.defaultButtonTitle = NSLocalizedString("OK", comment: "")
            alert?.alternateButtonTitle = ""
            alert?.setDefaultButtonAction(#selector(OEAlert.buttonAction(_:)), andTarget: alert)
            alert?.showsProgressbar = false
            
            return
        }
        
        coreDownload = pluginDL
        coreDownload?.start()
    }
    
    private func failInstallWithError(_ error: Error?) {
        alert?.close(withResult: .alertFirstButtonReturn)
        
        var plugin: OECorePlugin?
        if let coreIdentifier = coreIdentifier {
            plugin = OECorePlugin.corePlugin(bundleIdentifier: coreIdentifier)
        }
        completionHandler?(plugin, error)
        
        alert = nil
        coreIdentifier = nil
        completionHandler = nil
    }
    
    private func finishInstall() {
        alert?.close(withResult: .alertFirstButtonReturn)
        
        var plugin: OECorePlugin?
        if let coreIdentifier = coreIdentifier {
            plugin = OECorePlugin.corePlugin(bundleIdentifier: coreIdentifier)
        }
        completionHandler?(plugin, nil)
        
        alert = nil
        coreIdentifier = nil
        completionHandler = nil
    }
    
    // MARK: - Other user-initiated (= with error reporting) downloads
    
    func installCoreInBackgroundUserInitiated(_ download: CoreDownload) {
        assert(download.delegate === self, "download \(download)'s delegate is not the singleton CoreUpdater!?")
        
        pendingUserInitiatedDownloads.insert(download)
        
        download.start()
    }
}

// MARK: - CoreDownload Delegate

private var CoreDownloadProgressContext = 0

extension CoreUpdater: CoreDownloadDelegate {
    
    func coreDownloadDidStart(_ download: CoreDownload) {
        updateCoreList()
        
        download.addObserver(self, forKeyPath: #keyPath(CoreDownload.progress), options: [.new, .old, .initial, .prior], context: &CoreDownloadProgressContext)
    }
    
    func coreDownloadDidFinish(_ download: CoreDownload) {
        updateCoreList()
        
        download.removeObserver(self, forKeyPath: #keyPath(CoreDownload.progress), context: &CoreDownloadProgressContext)
        
        if download == coreDownload {
            finishInstall()
        }
        
        pendingUserInitiatedDownloads.remove(download)
    }
    
    func coreDownloadDidFail(_ download: CoreDownload, withError error: Error?) {
        updateCoreList()
        
        download.removeObserver(self, forKeyPath: #keyPath(CoreDownload.progress), context: &CoreDownloadProgressContext)
        
        if download == coreDownload {
            failInstallWithError(error)
        }
        
        if pendingUserInitiatedDownloads.contains(download),
           let error = error {
            NSApp.presentError(error)
        }
        
        pendingUserInitiatedDownloads.remove(download)
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?) {
        
        guard context == &CoreDownloadProgressContext else {
            return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
        }
        
        if let object = object as? CoreDownload,
           object == coreDownload {
            alert?.progress = coreDownload!.progress
        }
    }
}

// MARK: -

private typealias Architecture = String
private extension Architecture {
    static let arm64 = "arm64"
    static let x86_64 = "x86_64"
}

private struct Core: Codable {
    let id, name: String
    let systems: [String]
    let releases: [Release]
    private let experimental, deprecated: Bool?
    
    var isExperimental: Bool {
        experimental == true
    }
    
    var isDeprecated: Bool {
        deprecated == true
    }
    
    var latestSupportedRelease: Release? {
        var rel: Release?
        let supportedReleases = releases.filter { $0.isSupported }
        
        for release in supportedReleases {
            if rel == nil || SUStandardVersionComparator.default.compareVersion(rel!.version, toVersion: release.version) != .orderedDescending {
                rel = release
            }
        }
        
        return rel
    }
    
    struct Release: Codable {
        let version, url, sha256: String
        let minimumSystemVersion: String
        let architectures: [Architecture]
        
        var isSupported: Bool {
            var isSupported = SUStandardVersionComparator.default.compareVersion(minimumSystemVersion, toVersion: Self.osVersionString) != .orderedDescending
#if arch(arm64)
            return isSupported && architectures.contains(.arm64)
#elseif arch(x86_64)
            return isSupported && architectures.contains(.x86_64)
#endif
        }
        
        private static let osVersionString: String = {
            let osVersion = ProcessInfo.processInfo.operatingSystemVersion
            return "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
        }()
    }
}

private extension OECorePlugin {
    
    var architectures: [Architecture] {
        var architectures: [Architecture] = []
        let executableArchitectures = bundle.executableArchitectures as? [Int] ?? []
        if executableArchitectures.contains(NSBundleExecutableArchitectureX86_64) {
            architectures.append(.x86_64)
        }
        if #available(macOS 11.0, *),
           executableArchitectures.contains(NSBundleExecutableArchitectureARM64)
        {
            architectures.append(.arm64)
        }
        return architectures
    }
}
