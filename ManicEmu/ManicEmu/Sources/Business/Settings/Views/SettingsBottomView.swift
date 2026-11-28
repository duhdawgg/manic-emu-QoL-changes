//
//  SettingsBottomView.swift
//  ManicEmu
//
//  Created by Daiuno on 2026/6/25.
//  Copyright © 2026 Manic EMU. All rights reserved.
//

class SettingsBottomView: BaseView {
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        // QoL build: the donate and rate-us cards (for upstream Manic) are removed.
        let infoView = SettingsInfoView()
        addSubview(infoView)
        infoView.snp.makeConstraints { make in
            make.leading.trailing.top.equalToSuperview()
        }
    }
    
    @MainActor required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
