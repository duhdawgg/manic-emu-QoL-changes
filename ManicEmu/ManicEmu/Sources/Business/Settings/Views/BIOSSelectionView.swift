//
//  BIOSSelectionView.swift
//  ManicEmu
//
//  Created by Daiuno on 2025/6/10.
//  Copyright © 2025 Manic EMU. All rights reserved.
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import UIKit
import UniformTypeIdentifiers
import IceCream
import ZipArchive

class BIOSSelectionView: BaseView {
    
    // QoL build: only the systems this build ships.
    private enum SectionIndex: Int, CaseIterable {
        case _3ds, ds, gba, gbc, gb
        var title: String { gameType.localizedName }
        
        var gameType: GameType {
            switch self {
            case ._3ds: return ._3ds
            case .ds: return .ds
            case .gba: return .gba
            case .gbc: return .gbc
            case .gb: return .gb
            }
        }
    }
    
    private let gameType: GameType?
    private var biosItemMaps: [GameType: [BIOSItem]]
    private let showClose: Bool
    
    private lazy var listPageView: ASListPageView = {
        let view = ASListPageView(getListPage())
        view.didActionOccurred = { [weak self] action in
            guard let self else { return }
            if let navigationValue = action.navigationValue {
                if navigationValue.isTapClose {
                    self.hide()
                }
            } else if let indexPath = action.normalItemValue?.indexPath {
                let gameType: GameType
                if let gt = self.gameType {
                    gameType = gt
                } else if let sectionIndex = SectionIndex(rawValue: indexPath.section) {
                    gameType = sectionIndex.gameType
                } else {
                    return
                }
                if gameType == .symbian {
                    SymbianFirmwareView.show()
                } else if gameType == .ngc {
                    self.showGamecubeIPLSheet(desc: gameType.biosItems.first?.desc)
                } else if gameType == ._3ds,
                          let items = self.biosItemMaps[gameType],
                          indexPath.row < items.count,
                          items[indexPath.row].fileName.lowercased() == "aes_keys.txt" {
                    self.importAesKeys()
                } else {
                    self.importBios(gameType: gameType)
                }
            }
        }
        return view
    }()
    
    required init?(parameters: Any...) {
        let gameType = parameters.compactMap({ $0 as? GameType }).first
        self.gameType = gameType
        self.showClose = parameters.compactMap({ $0 as? Bool }).first ?? true
        if let gameType {
            self.biosItemMaps = [gameType: gameType.biosItems]
        } else {
            self.biosItemMaps = SectionIndex.allCases.reduce([GameType: [BIOSItem]](), {
                $0 + [$1.gameType: $1.gameType.biosItems]
            })
        }
        super.init(frame: .zero)
        
        addSubview(listPageView)
        listPageView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
        
        reloadAllImportState()
    }
    
    convenience init(showClose: Bool) {
        self.init(parameters: showClose)!
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func getListPage() -> ASListPage {
        func firstSectionHeader(title: String) -> ASListPage.Supplementary {
            return .texts([
                .smallText(R.string.localizable.biosAlert() + "\n",
                           numberOfLines: 0),
                .init(attributes: .init(text: title,
                                        color: R.Color.LabelSecondary,
                                        font: R.Font.Subheadline(emphasis: true)))
            ], pin: false)
        }
        
        var sections: [ASListPage.Section]
        if let gameType,
            let index = SectionIndex.allCases.first(where: { $0.gameType == gameType }) {
            var section = getSection(index: index)
            section.header = firstSectionHeader(title: index.title)
            sections = [section]
        } else {
            sections = SectionIndex.allCases.map({ getSection(index: $0) })
            if sections.count > 0 {
                sections[0].header = firstSectionHeader(title: SectionIndex.allCases.first!.title)
            }
        }
        
        var navigation = ASListPage.Navigation.defaultNavigation(title: "BIOS",
                                                                 titleIcon: .symbolImage(R.image.bios_iconSymbols()))
        navigation.enableClose = showClose
        
        return ASListPage(navigation: navigation,
                          sections: sections,
                          backgroundColor: .clear,
                          listInsets: .insets(bottom: R.Size.ContentInsetBottomForSettingPage(showAsDetail: (UIDevice.isPad && !showClose) || UIDevice.isPhoneDuoInnerFullScreen)),
                          pageInsets: .insets(top: showClose ? R.Size.SheetGrabberTopInset : R.Size.ContentInsetTop(window: hostingWindow)))
    }
    
    private func getCell(item: BIOSItem) -> ASListPage.Cell {
        var styles = [ASListPage.Cell.Style]()
        let subTitle: String
        if item.required {
            subTitle = "(\(R.string.localizable.optionTitleRequired()))"
        } else {
            subTitle = "(\(R.string.localizable.optionTitleOptional()))"
        }
        styles.append(.title(.largeText(item.fileName),
                             subTitle: .extraSmallText(subTitle,
                                                       color: item.required ? R.Color.Red : R.Color.LabelSecondary)))
        styles.append(.detail(.extraSmallText(item.desc)))
        let importTitle: String
        if item.imported {
            importTitle = R.string.localizable.biosImported()
        } else {
            importTitle = R.string.localizable.tabbarTitleImport()
        }
        if item.fileName == R.string.localizable.symbianOSFirmware() ||
            item.fileName == "nand.zip" ||
            item.fileName == "IPL.bin" {
            styles.append(.chevron(.init()))
        } else {
            styles.append(.button(.large(title: importTitle,
                                         titleColor: item.imported ? R.Color.Green : R.Color.Red,
                                         background: .clear)))
        }
        return .normal(styles)
    }
    
    private func getSection(index: SectionIndex) -> ASListPage.Section {
        let biosItems = biosItemMaps[index.gameType] ?? []
        return .init(cells: biosItems.map({ getCell(item: $0) }),
                     header: .defaultHeader(title: index.title))
    }
    
    private func reloadAllImportState() {
        DispatchQueue.global().async { [weak self] in
            guard let self else { return }
            for gameType in self.biosItemMaps.keys {
                guard gameType != .symbian else { continue }
                self.reloadImportState(gameType: gameType, updateViews: false)
            }
            DispatchQueue.main.async {
                self.listPageView.updatePage(self.getListPage())
            }
        }
    }
    
    private func reloadImportState(gameType: GameType, updateViews: Bool) {
        let fileManager = FileManager.default
        guard var biosItems = self.biosItemMaps[gameType] else { return }
        for (index, bios) in biosItems.enumerated() {
            if bios.fileName.lowercased() == "aes_keys.txt" {
                biosItems[index].imported = fileManager.fileExists(atPath: R.Path.ThreeDSSystemData.appendingPathComponent("aes_keys.txt"))
                continue
            }
            var biosInLib = R.Path.System.appendingPathComponent(bios.fileName)
            if gameType == .ngc {
                let imported = [R.Path.GamecubeUserEUR, R.Path.GamecubeUserJAP, R.Path.GamecubeUserUSA]
                    .contains { fileManager.fileExists(atPath: $0.appendingPathComponent("IPL.bin")) }
                biosItems[index].imported = imported
                continue
            } else if gameType == .dc {
                biosInLib = R.Path.Flycast.appendingPathComponent("dc/\(bios.fileName)")
            } else if gameType == .c64 {
                biosInLib = R.Path.System.appendingPathComponent("vice/\(bios.fileName)")
            }
            let isBiosExists: Bool
            if gameType == .arcade {
                isBiosExists = R.BIOS.MAMEBiosMap.keys.allSatisfy({
                    if R.BIOS.SegaArcadeBios.contains($0) {
                        return FileManager.default.fileExists(atPath: R.Path.Flycast.appendingPathComponent("dc/\($0)"))
                    } else {
                        return FileManager.default.fileExists(atPath: R.Path.Data.appendingPathComponent($0))
                    }
                })
            } else {
                isBiosExists = fileManager.fileExists(atPath: biosInLib)
            }
            if isBiosExists {
                biosItems[index].imported = true
            } else {
                let biosInDoc = R.Path.BIOS.appendingPathComponent(bios.fileName)
                if fileManager.fileExists(atPath: biosInDoc) {
                    try? FileManager.safeCopyItem(at: URL(fileURLWithPath: biosInDoc), to: URL(fileURLWithPath: biosInLib))
                    biosItems[index].imported = true
                }
            }
        }
        self.biosItemMaps[gameType] = biosItems
        if updateViews {
            self.listPageView.updatePage(self.getListPage())
        }
    }
    
    private func showGamecubeIPLSheet(desc: String?) {
        let iplFileName = "IPL.bin"
        let regions: [(title: String, directory: String)] = [
            ("EUR IPL.bin", R.Path.GamecubeUserEUR),
            ("JAP IPL.bin", R.Path.GamecubeUserJAP),
            ("USA IPL.bin", R.Path.GamecubeUserUSA)
        ]
        
        func makeCell(title: String, directory: String) -> ASListPage.Cell {
            let imported = FileManager.default.fileExists(atPath: directory.appendingPathComponent(iplFileName))
            let importTitle = imported ? R.string.localizable.biosImported() : R.string.localizable.tabbarTitleImport()
            var button = ASButton.large(title: importTitle,
                                        titleColor: imported ? R.Color.Green : R.Color.Red,
                                        background: .clear)
            button.state = .disabled
            return .normal([
                .title(.largeText(title)),
                .button(button)
            ])
        }
        
        var detailText: ASText? = nil
        if let desc {
            detailText = .smallText(desc, numberOfLines: 0)
        }
        
        var sheetStyle: ASSheet.Style = .simpleList(icon: .symbolImage(R.image.bios_iconSymbols()),
                                                    title: "GameCube BIOS",
                                                    detail: detailText,
                                                    options: regions.map { [makeCell(title: $0.title, directory: $0.directory)] })
        
        ASSheetView.show(.init(style: sheetStyle), action: { [weak self] action, updation in
            if let indexPath = action.listPageValue?.normalItemValue?.indexPath,
               indexPath.section < regions.count {
                let region = regions[indexPath.section]
                FilesImporter.shared.presentImportController(supportedTypes: UTType.binTypes, allowsMultipleSelection: false, manualHandle: { urls in
                    UIView.makeLoading()
                    DispatchQueue.global().async {
                        // Match IPL.bin case-insensitively; always write as IPL.bin.
                        let matched = urls.first(where: { $0.lastPathComponent.lowercased() == iplFileName.lowercased() })
                        var success = false
                        if let matched {
                            let destURL = URL(fileURLWithPath: region.directory.appendingPathComponent(iplFileName))
                            do {
                                try FileManager.safeCopyItem(at: matched, to: destURL, shouldReplace: true)
                                success = FileManager.default.fileExists(atPath: destURL.path)
                            } catch {
                                success = false
                            }
                        }
                        DispatchQueue.main.async {
                            UIView.hideLoading()
                            if success {
                                UIView.makeToast(message: R.string.localizable.biosImportSuccess(iplFileName))
                                if case let .simpleList(icon, title, detail, options, cancelEnable) = sheetStyle {
                                    var cells = options
                                    cells[indexPath.section][0] = makeCell(title: region.title, directory: region.directory)
                                    sheetStyle = .simpleList(icon: icon,
                                                              title: title,
                                                              detail: detail,
                                                              options: cells,
                                                              cancelEnable: cancelEnable)
                                    updation?(sheetStyle)
                                }
                                self?.reloadImportState(gameType: .ngc, updateViews: false)
                            } else {
                                UIView.makeToast(message: R.string.localizable.biosImportFailed())
                            }
                        }
                    }
                }, in: self?.hostingWindowScene)
                return .none
            }
            return .dismiss()
        })
    }
    
    private func importAesKeys() {
        var types = UTType.binTypes
        types.append(.plainText)
        FilesImporter.shared.presentImportController(supportedTypes: types, allowsMultipleSelection: false, manualHandle: { urls in
            UIView.makeLoading()
            DispatchQueue.global().async {
                let fileName = "aes_keys.txt"
                let matched = urls.first { $0.lastPathComponent.lowercased() == fileName }
                var success = false
                if let matched {
                    let destination = URL(fileURLWithPath: R.Path.ThreeDSSystemData.appendingPathComponent(fileName))
                    do {
                        try FileManager.safeCopyItem(at: matched, to: destination, shouldReplace: true)
                        success = FileManager.default.fileExists(atPath: destination.path)
                    } catch {
                        success = false
                    }
                }
                DispatchQueue.main.async { [weak self] in
                    UIView.hideLoading()
                    if success {
                        UIView.makeToast(message: R.string.localizable.biosImportSuccess(fileName))
                        self?.reloadImportState(gameType: ._3ds, updateViews: true)
                    } else {
                        UIView.makeToast(message: R.string.localizable.biosImportFailed())
                    }
                }
            }
        }, in: hostingWindowScene)
    }

    private func importBios(gameType: GameType) {
        func importFromFiles() {
            FilesImporter.shared.presentImportController(supportedTypes: UTType.binTypes, allowsMultipleSelection: true, manualHandle: { [weak self] urls in
                guard let self else { return }
                UIView.makeLoading()
                DispatchQueue.global().async { [weak self] in
                    guard let self else { return }
                    var matchs = [(url: URL, fileName: String)]()
                    var mameMatchs = [(url: URL, fileName: String)]()
                    for url in urls {
                        guard let biosItems = self.biosItemMaps[gameType] else { continue }
                        biosItems.forEach({ bios in
                            if url.lastPathComponent.lowercased() == bios.fileName.lowercased() {
                                matchs.append((url, bios.fileName))
                            } else if bios.fileName == R.Strings.MAMEBiosTitle,
                                      let _ = R.BIOS.MAMEBiosMap[url.lastPathComponent.lowercased()] {
                                //MAME Bios特殊匹配
                                mameMatchs.append((url, url.lastPathComponent.lowercased()))
                            }
                        })
                    }
                    
                    var import3DSNandSuccess = true
                    if matchs.count > 0 {
                        for match in matchs {
                            if match.fileName.lowercased() == "nand.zip" {
                                import3DSNandSuccess = self.import3DSNand(url: match.url)
                            } else {
                                try? FileManager.safeCopyItem(at: match.url, to: URL(fileURLWithPath: R.Path.BIOS.appendingPathComponent(match.fileName)), shouldReplace: true)
                                var matchFilePath = R.Path.System.appendingPathComponent(match.fileName)
                                if gameType == .dc {
                                    matchFilePath = R.Path.Flycast.appendingPathComponent("dc/\(match.fileName)")
                                } else if gameType == .c64 {
                                    try? FileManager.default.createDirectory(atPath: R.Path.System.appendingPathComponent("vice"), withIntermediateDirectories: true)
                                    matchFilePath = R.Path.System.appendingPathComponent("vice/\(match.fileName)")
                                }
                                try? FileManager.safeCopyItem(at: match.url, to: URL(fileURLWithPath: matchFilePath), shouldReplace: true)
                            }
                        }
                        if !import3DSNandSuccess {
                            matchs.removeAll(where: { $0.fileName.lowercased() == "nand.zip" })
                        }
                    }
                    
                    if mameMatchs.count > 0 {
                        for match in mameMatchs {
                            if R.BIOS.SegaArcadeBios.contains(match.fileName) {
                                //Some Sega arcade games need the flycast core to run, so copy the bios to the dc directory.
                                try? FileManager.safeCopyItem(at: match.url,
                                                              to: URL(fileURLWithPath: R.Path.Flycast.appendingPathComponent("dc/\(match.fileName)")),
                                                              shouldReplace: true)
                            } else {
                                try? FileManager.safeCopyItem(at: match.url, to: URL(fileURLWithPath: R.Path.Data.appendingPathComponent(match.fileName)), shouldReplace: true)
                            }
                        }
                    }
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        UIView.hideLoading()
                        if matchs.count > 0 || mameMatchs.count > 0 {
                            UIView.makeToast(message: R.string.localizable.biosImportSuccess((matchs+mameMatchs).reduce("") { $0 + $1.fileName + "\n" }))
                            
                            self.reloadImportState(gameType: gameType, updateViews: true)
                            
                            if gameType == .ds {
                                let ndsBiosCompletion = gameType.isNDSBiosComplete()
                                let realm = Database.realm
                                var games = [Game]()
                                if ndsBiosCompletion.isDSComplete, realm.object(ofType: Game.self, forPrimaryKey: Game.DsHomeMenuPrimaryKey) == nil {
                                    let game = Game()
                                    game.id = Game.DsHomeMenuPrimaryKey
                                    game.name = Game.DsHomeMenuPrimaryKey
                                    games.append(game)
                                }
                                if ndsBiosCompletion.isDsiComplete, realm.object(ofType: Game.self, forPrimaryKey: Game.DsiHomeMenuPrimaryKey) == nil {
                                    //新增Home Menu (DSi)
                                    let game = Game()
                                    game.id = Game.DsiHomeMenuPrimaryKey
                                    game.name = Game.DsiHomeMenuPrimaryKey
                                    games.append(game)
                                }
                                if games.count > 0 {
                                    games.forEach { game in
                                        game.fileExtension = "ds"
                                        game.gameType = .ds
                                        game.importDate = Date()
                                    }
                                    try? realm.write { realm.add(games) }
                                }
                            }
                            
                        } else {
                            UIView.makeToast(message: R.string.localizable.biosImportFailed())
                        }
                        
                        if !import3DSNandSuccess {
                            UIView.makeToast(message: R.string.localizable.threeDSNandImportFailed())
                        }
                    }
                }
            }, in: hostingWindowScene)
        }
        
        if gameType == ._3ds {
            UIView.makeAlert(title: R.string.localizable.headsUp(),
                             detail: R.string.localizable.nandImportHeadsUp(),
                             cancelTitle: R.string.localizable.contineFilesImport(),
                             confirmTitle: R.string.localizable.openPage(R.string.localizable.articBaseSettings()),
                             cancelAction: {
                UIView.makeToast(message: R.string.localizable.threeDSNandImportToast())
                importFromFiles()
            }, confirmAction: {
                DispatchQueue.main.asyncAfter(delay: 0.35) {
                    PretendoNetworkingView.show()
                }
            })
        } else {
            importFromFiles()
        }
    }
    
    private func import3DSNand(url: URL) -> Bool {
        //先检查zip里面有没有支持的文件类型
        if SSZipArchive.isFilePasswordProtected(atPath: url.path) {
            return false
        } else {
            let unZipPath = R.Path.Cache.appendingPathComponent("nand")
            if FileManager.default.fileExists(atPath: unZipPath) {
                try? FileManager.default.removeItem(atPath: unZipPath)
            }
            let unzipSuccess = SSZipArchive.unzipFile(atPath: url.path, toDestination: unZipPath)
            guard unzipSuccess else { return false }
            
            var tempNandPath = unZipPath
            if FileManager.default.fileExists(atPath: unZipPath.appendingPathComponent("nand")) {
                tempNandPath = unZipPath.appendingPathComponent("nand")
            }
            
            let nandPath = R.Path.ThreeDS.appendingPathComponent("nand")
            try? FileManager.safeReplaceDirectory(at: URL(fileURLWithPath: tempNandPath), to: URL(fileURLWithPath: nandPath))
            
            try? FileManager.default.removeItem(atPath: unZipPath)
            
            import3DSHomeMenu(at: nandPath)
   
            return true
        }
    }
    
    private func import3DSHomeMenu(at path: String) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return }
        
        if path.pathExtension.lowercased() == "app", let tid = pathToTid(path),
           R.Numbers.ThreeDSHomeMenuIdentifiers.contains(where: { $0 == tid }) {
            // Leave the .app in NAND. Importing it as a ROM copies onto the same path and deletes it.
            ThreeDS.registerInstalledHomeMenu(at: URL(fileURLWithPath: path), identifier: tid)
        }
        
        if isDirectory.boolValue {
            do {
                let contents = try fileManager.contentsOfDirectory(atPath: path)
                for item in contents {
                    let fullPath = (path as NSString).appendingPathComponent(item)
                    import3DSHomeMenu(at: fullPath)
                }
            } catch {
                Log.debug("Failed to read NAND directory \(path): \(error)")
            }
        }
    }
    
    // String -> UInt64
    private func pathToTid(_ path: String) -> UInt64? {
        guard let beginRange = path.range(of: "/title/") else { return nil }
        guard let endRange = path.range(of: "/content/") else { return nil }
        guard beginRange.upperBound < endRange.lowerBound else { return nil }
        
        let path = String(path[beginRange.upperBound..<endRange.lowerBound])
        
        let parts = path.split(separator: "/")
        guard parts.count == 2,
              let high = UInt32(parts[0], radix: 16),
              let low = UInt32(parts[1], radix: 16) else {
            return nil
        }
        return (UInt64(high) << 32) | UInt64(low)
    }
}

extension BIOSSelectionView: ShowableView {
    static func show(gameType: GameType) {
        Self.show(parameters: gameType)
    }
}
