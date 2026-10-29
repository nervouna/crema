#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
check_dir=$(mktemp -d /private/tmp/crema-checks.XXXXXX)
say -v 'Tingting (Chinese (China mainland))' -r 165 -o "$check_dir/meeting.aiff" '今天讨论 Crema 的第一个版本。界面使用 SwiftUI，录音结束后再转写。所有会议内容只在本机处理，不接入云服务。决定先支持中文会议和英文技术名词。小王负责录音功能，本周五之前完成。预算暂时没有确定，下一次会议再讨论。'
# Both model directories must already exist. The test process cannot open network connections.
CREMA_DATA_DIRECTORY="$check_dir/Meetings" /usr/bin/time -l /usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    .build/Build/Products/Release/Crema.app/Contents/MacOS/Crema \
    --self-test --audio "$check_dir/meeting.aiff" --test-ai | tee "$check_dir/results.log"
print "Checks and generated meeting: $check_dir"
