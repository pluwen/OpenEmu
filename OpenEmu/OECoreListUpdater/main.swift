// Copyright (c) 2022, OpenEmu Team
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
import ZIPFoundation

private typealias Architecture = String
private extension Architecture {
    static var arm64 = "arm64"
    static var x86_64 = "x86_64"
}

private class Core: Codable {
    let id, name: String
    let systems: [String]
    var releases: [Release]
    let experimental, deprecated: Bool?
    
    struct Release: Codable {
        let version, url, sha256: String
        let minimumSystemVersion: String
        let architectures: [Architecture]
    }
}

let repoNames = ["dolphin": "dolphin",
                 "picodrive": "picodrive",
                 "MAME": "UME-Core"]

func updateCores(jsonFile: URL, pluginURLs: [URL]) {
    let data: Data
    let cores: [Core]
    do {
        data = try Data(contentsOf: jsonFile)
        cores = try JSONDecoder().decode([Core].self, from: data)
    } catch {
        print(error)
        return
    }
    
    for pluginURL in pluginURLs {
        let isZipped = pluginURL.pathExtension == "zip"
        
        let tmpURL: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OECoreListUpdater", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        
        if isZipped {
            do {
                try FileManager.default.unzipItem(at: pluginURL, to: tmpURL)
            } catch {
                print(error)
                continue
            }
        }
        
        let bundleURL: URL
        if isZipped {
            guard let extractURL = (try? FileManager.default.contentsOfDirectory(at: tmpURL, includingPropertiesForKeys: []))?.first
            else { continue }
            bundleURL = extractURL
        } else {
            bundleURL = pluginURL
        }
        
        guard let bundle = Bundle(url: bundleURL),
              let infoDict = bundle.infoDictionary,
              let core = cores.first(where: { $0.id == bundle.bundleIdentifier?.lowercased() }),
              let version = infoDict["CFBundleVersion"] as? String,
              let execArchs = bundle.executableArchitectures as? [Int]
        else {
            continue
        }
        
        let minimumSystemVersion = infoDict["LSMinimumSystemVersion"] as? String ?? ""
        let url = "https://github.com/OpenEmu/\(repoNames[core.name, default: "\(core.name)-Core"])/releases/download/v\(version)/\(core.name)_\(version).zip"
        let sha256: String
        
        var architectures: [Architecture] = []
        if execArchs.contains(NSBundleExecutableArchitectureX86_64) {
            architectures.append(.x86_64)
        }
        if execArchs.contains(NSBundleExecutableArchitectureARM64) {
            architectures.append(.arm64)
        }
        
        let newPluginURL = pluginURL.deletingLastPathComponent().appendingPathComponent("\(core.name)_\(version).zip", isDirectory: false)
        
        if isZipped {
            do {
                sha256 = try FileManager.default.hashFile(at: pluginURL, hashFunction: .sha256)
                try FileManager.default.moveItem(at: pluginURL, to: newPluginURL)
            } catch {
                print(error)
                continue
            }
            
            try? FileManager.default.removeItem(at: tmpURL)
        } else {
            do {
                try FileManager.default.zipItem(at: pluginURL, to: newPluginURL, compressionMethod: .deflate)
                sha256 = try FileManager.default.hashFile(at: newPluginURL, hashFunction: .sha256)
            } catch {
                print(error)
                continue
            }
        }
        
        let release = Core.Release(version: version, url: url, sha256: sha256, minimumSystemVersion: minimumSystemVersion, architectures: architectures)
        
        core.releases.append(release)
    }
    
    let jsonEncoder = JSONEncoder()
    jsonEncoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let jsonData = try? jsonEncoder.encode(cores),
       let jsonString = String(data: jsonData, encoding: .utf8)
    {
        do {
            try (jsonString + "\n").write(to: jsonFile, atomically: false, encoding: .utf8)
        } catch {
            print(error)
        }
    }
}

let arguments = CommandLine.arguments
guard let jsonFilePath = arguments.first(where: { $0.hasSuffix(".json") })
else {
    print("No .json file specified.")
    exit(EXIT_FAILURE)
}
let jsonFile = URL(fileURLWithPath: jsonFilePath)
var pluginURLs: [URL] = []
for argument in arguments.filter({ $0.hasSuffix(".zip") || $0.hasSuffix(".oecoreplugin") }) {
    pluginURLs.append(URL(fileURLWithPath: argument))
}

updateCores(jsonFile: jsonFile, pluginURLs: pluginURLs)
