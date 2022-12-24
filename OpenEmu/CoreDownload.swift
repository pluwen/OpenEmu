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

final class CoreDownload: NSObject {
    
    weak var delegate: CoreDownloadDelegate?
    
    var name = ""
    var systemIdentifiers: [String] = []
    var systemNames: [String] = []
    var version = ""
    var bundleIdentifier = ""
    
    var hasUpdate = false
    var canBeInstalled = false
    
    var url: URL?
    var sha256: String?
    
    private(set) var isDownloading = false
    @objc private(set) dynamic var progress: Double = 0
    
    private var downloadSession: URLSession?
    
    convenience init(plugin: OECorePlugin) {
        self.init()
        updateProperties(with: plugin)
    }
    
    func start() {
        guard let url = url, !isDownloading else { return }
        
        assert(downloadSession == nil, "There shouldn't be a previous download session.")
        
        let downloadSession = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        downloadSession.sessionDescription = bundleIdentifier
        self.downloadSession = downloadSession
        
        let downloadTask = downloadSession.downloadTask(with: url)
        
        DLog("Starting core download (\(downloadSession.sessionDescription ?? ""))")
        
        downloadTask.resume()
        
        isDownloading = true
        delegate?.coreDownloadDidStart(self)
    }
    
    func cancel() {
        DLog("Cancelling core download (\(downloadSession?.sessionDescription ?? ""))")
        downloadSession?.invalidateAndCancel()
    }
    
    private func updateProperties(with plugin: OECorePlugin) {
        name = plugin.displayName
        version = plugin.version
        hasUpdate = false
        canBeInstalled = false
        
        var systemNames: [String] = []
        for systemIdentifier in plugin.systemIdentifiers {
            if let plugin = OESystemPlugin.systemPlugin(forIdentifier: systemIdentifier) {
               let systemName = plugin.systemName
                systemNames.append(systemName)
            }
        }
        
        self.systemNames = systemNames
        systemIdentifiers = plugin.systemIdentifiers
        bundleIdentifier = plugin.bundleIdentifier
    }
}

extension CoreDownload: URLSessionDownloadDelegate {
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        
        DLog("Core download (\(session.sessionDescription ?? "")) did complete: \(error?.localizedDescription ?? "no errors")")
        
        isDownloading = false
        progress = 0
        
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        
        if let error = error {
            delegate?.coreDownloadDidFail(self, withError: error)
        } else {
            delegate?.coreDownloadDidFinish(self)
        }
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        
        progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
    }
    
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        
        DLog("Core download (\(session.sessionDescription ?? "")) did finish downloading temporary data.")
        
        let fm = FileManager.default
        guard let sha256 = try? fm.hashFile(at: location, hashFunction: .sha256),
              sha256 == self.sha256
        else {
            os_log(.error, log: .default, "Checksum mismatch for core download %{public}@", bundleIdentifier)
            try? fm.removeItem(at: location)
            return
        }
        
        let coresFolder = URL.oeApplicationSupportDirectory
            .appendingPathComponent("Cores", isDirectory: true)
        
        guard
            let fileName = ArchiveHelper.decompressFileInArchive(at: location, toDirectory: coresFolder)
        else { return }
        
        let fullPluginURL = coresFolder.appendingPathComponent(fileName)
        
        DLog("Core (\(bundleIdentifier)) extracted to application support folder.")
        
        guard let plugin = OECorePlugin.corePlugin(bundleAtURL: fullPluginURL) else {
            return assertionFailure()
        }
        
        if hasUpdate {
            // flush bundle cache as NSBundle still returns the infoDictionary of the previous version
            plugin.flushBundleCache()
            version = plugin.version
            hasUpdate = false
            canBeInstalled = false
        }
        else if canBeInstalled {
            updateProperties(with: plugin)
        }
    }
}

protocol CoreDownloadDelegate: AnyObject {
    func coreDownloadDidStart(_ download: CoreDownload)
    func coreDownloadDidFinish(_ download: CoreDownload)
    func coreDownloadDidFail(_ download: CoreDownload, withError error: Error?)
}
