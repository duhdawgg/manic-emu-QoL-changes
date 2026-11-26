/*
    Copyright 2023 Jesse Talavera-Greenberg

    melonDS DS is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free
    Software Foundation, either version 3 of the License, or (at your option)
    any later version.

    melonDS DS is distributed in the hope that it will be useful, but WITHOUT ANY
    WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
    FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

    You should have received a copy of the GNU General Public License along
    with melonDS DS. If not, see http://www.gnu.org/licenses/.
*/

#include "parse.hpp"

#include <optional>

#include <net/net_compat.h>
#include "../environment.hpp"

std::optional<melonDS::IpAddress> MelonDsDs::ParseIpAddress(std::string_view value) noexcept {
    ZoneScopedN(TracyFunction);
    if (value.empty())
        return std::nullopt;

    in_addr address;
    if (inet_pton(AF_INET, value.data(), &address) == 1) {
        // Both in_addr and ip represent an IPv4 address,
        // but they may have different alignment requirements.
        // Better safe than sorry.
        melonDS::IpAddress ip {};
        memcpy(&ip, &address, sizeof(address));
        return ip;
    }

    return std::nullopt;
}

MelonDsDs::CustomLayoutParams MelonDsDs::ParseCustomLayoutConfig(std::string_view value) noexcept {
    CustomLayoutParams params;
    retro::debug(">>>>>开始解析自定义布局: {}", value);
    if (value.empty()) {
        retro::debug("自定义布局为空");
        return params;
    }
    
    // Simple comma-separated parsing
    // Expected format: "topX,topY,topWidth,topHeight,bottomX,bottomY,bottomWidth,bottomHeight,bufferWidth,bufferHeight"
    // Now supports floating-point values like "100.5,200.25,256.0,192.0,300.75,0,256,192,512,384"
    size_t pos = 0;
    float values[10] = {0.0f};
    int valueIndex = 0;
    
    while (pos < value.length() && valueIndex <= 10) {
        size_t commaPos = value.find(',', pos);
        if (commaPos == std::string_view::npos) {
            commaPos = value.length();
        }
        
        std::string_view numberStr = value.substr(pos, commaPos - pos);
        
        if (numberStr.empty()) {
            retro::debug("自定义布局格式错误1");
            return params;  // Invalid format
        }
        
        // Parse floating-point number
        float num = 0.0f;
        float decimal = 0.0f;
        float divisor = 1.0f;
        bool hasDecimal = false;
        bool validNumber = true;
        bool negative = false;
        int decimalDigits = 0;
        
        size_t i = 0;
        if (!numberStr.empty() && numberStr[0] == '-') {
            negative = true;
            i = 1;
            if (i >= numberStr.length()) {
                retro::debug("自定义布局格式错误2");
                return params;  // Invalid: only negative sign
            }
        }
        
        bool hasDigits = false;
        bool hasDigitsAfterDecimal = false;
        
        for (; i < numberStr.length(); ++i) {
            char c = numberStr[i];
            if (c >= '0' && c <= '9') {
                hasDigits = true;
                if (hasDecimal) {
                    hasDigitsAfterDecimal = true;
                    // Limit decimal precision to avoid overflow
                    if (decimalDigits < 10) {  // Only process first 10 decimal digits
                        decimal = decimal * 10.0f + (c - '0');
                        divisor *= 10.0f;
                        decimalDigits++;
                    }
                    // Ignore additional decimal digits but continue parsing
                } else {
                    num = num * 10.0f + (c - '0');
                    if (num > 99999.0f) {  // Reasonable limits for integer part
                        validNumber = false;
                        break;
                    }
                }
            } else if (c == '.' && !hasDecimal) {
                hasDecimal = true;
            } else {
                validNumber = false;
                break;
            }
        }
        
        // Validate number format
        if (!validNumber || !hasDigits || (hasDecimal && !hasDigitsAfterDecimal)) {
            retro::debug("自定义布局格式错误3 - 数值: '{}', 索引: {}, validNumber: {}, hasDigits: {}, hasDecimal: {}, hasDigitsAfterDecimal: {}", 
                        std::string(numberStr), valueIndex, validNumber, hasDigits, hasDecimal, hasDigitsAfterDecimal);
            return params;  // Invalid format
        }
        
        float finalValue = num + (decimal / divisor);
        if (negative) {
            finalValue = -finalValue;
        }
        
        retro::debug("解析数值 {}: '{}' -> {}", valueIndex, std::string(numberStr), finalValue);
        
        if (valueIndex < 10) {
            values[valueIndex] = finalValue;
        }
        valueIndex++;
        pos = commaPos + 1;
    }
    
    // Need exactly 10 values
    if (valueIndex == 10) {
        params.topX = values[0];
        params.topY = values[1];
        params.topWidth = values[2];
        params.topHeight = values[3];
        params.bottomX = values[4];
        params.bottomY = values[5];
        params.bottomWidth = values[6];
        params.bottomHeight = values[7];
        params.bufferWidth = values[8];
        params.bufferHeight = values[9];
        params.valid = true;
    }

    // 打印params
    retro::debug("自定义布局参数: topX={}, topY={}, topWidth={}, topHeight={}, bottomX={}, bottomY={}, bottomWidth={}, bottomHeight={}, bufferWidth={}, bufferHeight={}, valid={}",
        params.topX, params.topY, params.topWidth, params.topHeight,
        params.bottomX, params.bottomY, params.bottomWidth, params.bottomHeight,
        params.bufferWidth, params.bufferHeight, params.valid);
    
    return params;
}