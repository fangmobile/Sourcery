//
//  main.swift
//  Sourcery
//
//  Created by Krzysztof Zablocki on 09/12/2016.
//  Copyright © 2016 Pixle. All rights reserved.
//

import Foundation
import Commander
import PathKit
import SourceryRuntime
import SourceryFramework
import SourceryUtils
import SourceryJS

extension Path: ArgumentConvertible {
    /// :nodoc:
    public init(parser: ArgumentParser) throws {
        if let path = parser.shift() {
            self.init(path)
        } else {
            throw ArgumentError.missingValue(argument: nil)
        }
    }
}

private enum Validators {
    static func isReadable(path: Path) -> Path {
        if !path.isReadable {
            Log.error("'\(path)' does not exist or is not readable.")
            exit(.invalidePath)
        }

        return path
    }

    static func isFileOrDirectory(path: Path) -> Path {
        _ = isReadable(path: path)

        if !(path.isDirectory || path.isFile) {
            Log.error("'\(path)' isn't a directory or proper file.")
            exit(.invalidePath)
        }

        return path
    }

    static func isWritable(path: Path) -> Path {
        if path.exists && !path.isWritable {
            Log.error("'\(path)' isn't writable.")
            exit(.invalidePath)
        }
        return path
    }
}

extension Configuration {

    func validate() {
        guard !source.isEmpty else {
            Log.error("No sources provided.")
            exit(.invalidConfig)
        }
        if case let .sources(sources) = source {
            _ = sources.allPaths.map(Validators.isReadable(path:))
        }
        _ = templates.allPaths.map(Validators.isReadable(path:))
        guard !templates.isEmpty else {
            Log.error("No templates provided.")
            exit(.invalidConfig)
        }
        _ = output.path.map(Validators.isWritable(path:))
    }

}

enum ExitCode: Int32 {
    case invalidePath = 1
    case invalidConfig
    case other
}

private func exit(_ code: ExitCode) -> Never {
    exit(code.rawValue)
}

func runCLI() {
    command(
        Flag("watch", flag: "w", description: "Watch template for changes and regenerate as needed."),
        Flag("disableCache", description: "Stops using cache."),
        Flag("verbose", flag: "v", description: "Turn on verbose logging, this causes to log everything we can."),
        Flag("logAST", description: "Log AST messages"),
        Flag("logBenchmarks", description: "Log time benchmark info"),
        Flag("quiet", flag: "q", description: "Turn off any logging, only emmit errors."),
        Flag("prune", flag: "p", description: "Remove empty generated files"),
        VariadicOption<Path>("sources", description: "Path to a source swift files. File or Directory."),
        VariadicOption<Path>("exclude-sources", description: "Path to a source swift files to exclude. File or Directory."),
        VariadicOption<Path>("templates", description: "Path to templates. File or Directory."),
        VariadicOption<Path>("exclude-templates", description: "Path to templates to exclude. File or Directory."),
        Option<Path>("output", default: "", description: "Path to output. File or Directory. Default is current path."),
        Option<Path>("config", default: ".", description: "Path to config file. File or Directory. Default is current path."),
        VariadicOption<String>("force-parse", description: "File extensions that Sourcery will be forced to parse, even if they were generated by Sourcery."),
        VariadicOption<String>("args", description: "Custom values to pass to templates."),
        Option<Path>("ejsPath", default: "", description: "Path to EJS file for JavaScript templates.")
    ) { watcherEnabled, disableCache, verboseLogging, logAST, logBenchmark, quiet, prune, sources, excludeSources, templates, excludeTemplates, output, configPath, forceParse, args, ejsPath in
        do {
            switch (quiet, verboseLogging) {
            case (true, _):
                Log.level = .errors
            case (false, let isVerbose):
                Log.level = isVerbose ? .verbose : .info
            }
            Log.logBenchmarks = (verboseLogging || logBenchmark) && !quiet
            Log.logAST = (verboseLogging || logAST) && !quiet

            // if ejsPath is not provided use default value or executable path
            EJSTemplate.ejsPath = ejsPath.string.isEmpty
                ? (EJSTemplate.ejsPath ?? Path(ProcessInfo.processInfo.arguments[0]).parent() + "ejs.js")
                : ejsPath

            let configurations: [Configuration]
            let yamlPath: Path = configPath.isDirectory ? configPath + ".sourcery.yml" : configPath

            if !yamlPath.exists {
                Log.info("No config file provided or it does not exist. Using command line arguments.")
                let args = args.joined(separator: ",")
                let arguments = AnnotationsParser.parse(line: args)
                configurations = [
                    Configuration(
                        sources: Paths(include: sources, exclude: excludeSources) ,
                        templates: Paths(include: templates, exclude: excludeTemplates),
                        output: output.string.isEmpty ? "." : output,
                        cacheBasePath: Path.defaultBaseCachePath,
                        forceParse: forceParse,
                        args: arguments
                    )
                ]
            } else {
                _ = Validators.isFileOrDirectory(path: configPath)
                _ = Validators.isReadable(path: yamlPath)

                do {
                    let relativePath: Path = configPath.isDirectory ? configPath : configPath.parent()

                    configurations = try Configurations.make(
                        path: yamlPath,
                        relativePath: relativePath,
                        env: ProcessInfo.processInfo.environment
                    )

                    // Check if the user is passing parameters
                    // that are ignored cause read from the yaml file
                    let hasAnyYamlDuplicatedParameter = (
                        !sources.isEmpty ||
                            !excludeSources.isEmpty ||
                            !templates.isEmpty ||
                            !excludeTemplates.isEmpty ||
                            !forceParse.isEmpty ||
                            output != "" ||
                            !args.isEmpty
                    )

                    if hasAnyYamlDuplicatedParameter {
                        Log.info("Using configuration file at '\(yamlPath)'. WARNING: Ignoring the parameters passed in the command line.")
                    } else {
                        Log.info("Using configuration file at '\(yamlPath)'")
                    }
                } catch {
                    Log.error("while reading .yml '\(yamlPath)'. '\(error)'")
                    exit(.invalidConfig)
                }
            }

            let start = CFAbsoluteTimeGetCurrent()

            let keepAlive = try configurations.flatMap { configuration -> [FolderWatcher.Local] in
                configuration.validate()

                let sourcery = Sourcery(verbose: verboseLogging,
                                        watcherEnabled: watcherEnabled,
                                        cacheDisabled: disableCache,
                                        cacheBasePath: configuration.cacheBasePath,
                                        prune: prune,
                                        arguments: configuration.args)

                return try sourcery.processFiles(
                    configuration.source,
                    usingTemplates: configuration.templates,
                    output: configuration.output,
                    forceParse: configuration.forceParse
                ) ?? []
            }

            if keepAlive.isEmpty {
                Log.info("Processing time \(CFAbsoluteTimeGetCurrent() - start) seconds")
            } else {
                RunLoop.current.run()
                _ = keepAlive
            }
        } catch {
            Log.error("\(error)")
            exit(.other)
        }
        }.run(Sourcery.version)
}

#if os(macOS)
import AppKit

if !inUnitTests {
    runCLI()
} else {
    //! Need to run something for tests to work
    final class TestApplicationController: NSObject, NSApplicationDelegate {
        let window =   NSWindow()

        func applicationDidFinishLaunching(aNotification: NSNotification) {
            window.setFrame(CGRect(x: 0, y: 0, width: 0, height: 0), display: false)
            window.makeKeyAndOrderFront(self)
        }

        func applicationWillTerminate(aNotification: NSNotification) {
        }

    }

    autoreleasepool { () -> Void in
        let app =   NSApplication.shared
        let controller =   TestApplicationController()

        app.delegate   = controller
        app.run()
    }
}
#endif
