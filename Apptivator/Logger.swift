//
//  Logger.swift
//  Apptivator
//

import os

extension Logger {
    static let app = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.acheronfail.apptivator",
                            category: "app")
}
