pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
    id: root

    moduleName: "caniworknow.status"
    ipcTarget: "caniworknow.status"

    readonly property string origin: "https://caniworknow.com"
    readonly property int refreshIntervalSec: Math.max(300, Math.min(3600, Number(setting("refreshIntervalSec", 300)) || 300))
    readonly property string iconStyle: normalizedIconStyle(setting("iconStyle", "Thumbs"))
    readonly property color foreground: bar ? bar.foreground : Color.foreground
    readonly property color urgent: bar ? bar.urgent : Color.urgent
    readonly property color dim: Qt.darker(foreground, 1.5)
    readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

    property string answer: "unknown"
    property string checkedAt: ""
    property var services: []
    property double lastSuccessfulFetchAt: 0
    property string refreshError: ""
    property string refreshState: "idle"
    property string shareState: "idle"
    property bool announceRefresh: false
    property bool announceShare: false
    property bool shareCompleted: false

    readonly property bool hasKnownStatus: checkedAt !== "" && services.length > 0
    readonly property string verdictIcon: verdictGlyph(answer)
    readonly property string verdictTitle: answer === "yes" ? "You can work now" : answer === "no" ? "Some services are having trouble" : "Status unavailable"
    readonly property string verdictLabel: answer === "yes" ? "YES" : answer === "no" ? "NO" : "UNKNOWN"
    readonly property string checkedLabel: checkedAt === "" ? "No successful check yet" : "Last checked " + formatCheckedAt(checkedAt)

    function validStatus(value) {
        if (!value || typeof value !== "object")
            return false;
        if (["yes", "no", "unknown"].indexOf(value.answer) < 0)
            return false;
        if (typeof value.checkedAt !== "string" || !isFinite(Date.parse(value.checkedAt)))
            return false;
        return Array.isArray(value.services);
    }

    function normalizedIconStyle(value) {
        var name = String(value || "Thumbs");
        return ["Thumbs", "Checks", "Letters"].indexOf(name) >= 0 ? name : "Thumbs";
    }

    function verdictGlyph(value) {
        if (value === "unknown")
            return "?";
        if (iconStyle === "Letters")
            return value === "yes" ? "Y" : "N";
        if (iconStyle === "Checks")
            return value === "yes" ? "✓" : "×";
        return value === "yes" ? "\uf164" : "\uf165";
    }

    function finishRefresh(state) {
        if (!announceRefresh)
            return;
        announceRefresh = false;
        refreshState = state;
        refreshStateTimer.restart();
    }

    function finishShare(state) {
        shareCompleted = true;
        shareState = state;
        shareStateTimer.restart();
        if (announceShare) {
            var message = state === "copied" ? "Latest permalink copied" : "Could not copy the latest permalink";
            Quickshell.execDetached(["omarchy-notification-send", "Can I Work Now?", message]);
        }
        announceShare = false;
    }

    function applyStatus(raw) {
        var parsed;
        try {
            parsed = JSON.parse(String(raw || ""));
        } catch (error) {
            refreshError = "Could not read the latest global status";
            finishRefresh("error");
            return;
        }

        if (!validStatus(parsed)) {
            refreshError = "The global status response was incomplete";
            finishRefresh("error");
            return;
        }

        answer = parsed.answer;
        checkedAt = parsed.checkedAt;
        services = parsed.services;
        lastSuccessfulFetchAt = Date.now();
        refreshError = "";
        finishRefresh("refreshed");
    }

    function refresh(showFeedback) {
        if (statusProcess.running)
            return;
        if (showFeedback === true)
            announceRefresh = true;
        refreshError = "";
        statusProcess.running = true;
    }

    function shareLatest(showNotification) {
        if (shareProcess.running)
            return;
        announceShare = showNotification === true;
        shareCompleted = false;
        shareProcess.running = true;
    }

    function applyShare(raw) {
        var parsed;
        try {
            parsed = JSON.parse(String(raw || ""));
        } catch (error) {
            finishShare("error");
            return;
        }

        var url = parsed && typeof parsed.url === "string" ? parsed.url : "";
        if (!/^https:\/\/[^/]+\/s\//.test(url)) {
            finishShare("error");
            return;
        }

        Quickshell.execDetached(["wl-copy", url]);
        finishShare("copied");
    }

    function formatCheckedAt(value) {
        var date = new Date(value);
        if (!isFinite(date.getTime()))
            return "—";
        return Qt.formatDateTime(date, "MMM d, h:mm AP");
    }

    function serviceLabel(health) {
        if (health === "operational")
            return "UP";
        if (health === "degraded")
            return "DEGRADED";
        if (health === "outage")
            return "DOWN";
        return "UNKNOWN";
    }

    function serviceIcon(health) {
        if (health === "operational")
            return "✓";
        if (health === "degraded" || health === "outage")
            return "!";
        return "?";
    }

    function serviceColor(health) {
        return health === "degraded" || health === "outage" ? urgent : health === "operational" ? foreground : dim;
    }

    onOpenedChanged: {
        if (opened && Date.now() - lastSuccessfulFetchAt > refreshIntervalSec * 1000)
            refresh(false);
    }

    Component.onCompleted: refresh(false)

    Timer {
        interval: root.refreshIntervalSec * 1000
        running: true
        repeat: true
        onTriggered: root.refresh(false)
    }

    Timer {
        id: refreshStateTimer
        interval: 1800
        repeat: false
        onTriggered: root.refreshState = "idle"
    }

    Timer {
        id: shareStateTimer
        interval: 2600
        repeat: false
        onTriggered: root.shareState = "idle"
    }

    Process {
        id: statusProcess
        command: ["curl", "-fsS", "--max-time", "8", "--header", "Accept: application/json", root.origin + "/api/status"]

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyStatus(text)
        }

        stderr: StdioCollector {
            waitForEnd: true
            onStreamFinished: {
                if (String(text || "").trim() !== "" && !root.hasKnownStatus)
                    root.refreshError = "Could not reach caniworknow.com";
            }
        }

        onExited: function (exitCode) {
            if (exitCode !== 0) {
                root.refreshError = "Could not reach caniworknow.com";
                root.finishRefresh("error");
            }
        }
    }

    Process {
        id: shareProcess
        command: ["curl", "-fsS", "--max-time", "8", "--request", "POST", "--header", "Accept: application/json", "--header", "Content-Type: application/json", "--data", "{}", root.origin + "/api/share"]

        stdout: StdioCollector {
            waitForEnd: true
            onStreamFinished: root.applyShare(text)
        }

        onExited: function (exitCode) {
            if (exitCode !== 0 && !root.shareCompleted)
                root.finishShare("error");
        }
    }

    implicitWidth: button.implicitWidth
    implicitHeight: button.implicitHeight

    BarIconButton {
        id: button
        anchors.fill: parent
        bar: root.bar
        text: root.verdictIcon
        fontSize: Style.font.icon

        onPressed: function (buttonCode) {
            if (buttonCode === Qt.RightButton)
                root.shareLatest(true);
            else if (buttonCode === Qt.MiddleButton)
                root.refresh(true);
            else
                root.toggle();
        }
    }

    KeyboardPanel {
        id: panel
        anchorItem: button
        owner: root
        bar: root.bar
        open: root.opened
        focusTarget: keyCatcher
        contentWidth: panel.fittedContentWidth(Style.space(390))
        contentHeight: panel.fittedContentHeight(content.implicitHeight)

        PanelKeyCatcher {
            id: keyCatcher
            anchors.fill: parent
            onCloseRequested: root.close()
            onTabRequested: function (direction) {
                root.switchPanel(direction);
            }
            onTextKey: function (text) {
                if (text === "r" || text === "R")
                    root.refresh(true);
                else if (text === "s" || text === "S")
                    root.shareLatest(false);
            }

            Column {
                id: content
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: Style.space(14)

                Item {
                    width: parent.width
                    implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight)

                    Text {
                        id: heroIcon
                        anchors.left: parent.left
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.verdictIcon
                        color: root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.displayLarge
                    }

                    Column {
                        id: heroLabels
                        anchors.left: heroIcon.right
                        anchors.leftMargin: Style.space(14)
                        anchors.right: heroAnswer.left
                        anchors.rightMargin: Style.space(12)
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(2)

                        Text {
                            width: parent.width
                            text: root.verdictTitle
                            color: root.foreground
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.title
                            font.bold: true
                            elide: Text.ElideRight
                        }

                        Text {
                            width: parent.width
                            text: root.checkedLabel.toUpperCase()
                            color: root.dim
                            font.family: root.fontFamily
                            font.pixelSize: Style.font.caption
                            font.bold: true
                            font.letterSpacing: 1
                            elide: Text.ElideRight
                        }
                    }

                    Text {
                        id: heroAnswer
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        text: root.verdictLabel
                        color: root.answer === "no" ? root.urgent : root.foreground
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.title
                        font.bold: true
                    }
                }

                PanelSeparator {
                    width: parent.width
                }

                Column {
                    width: parent.width
                    spacing: Style.space(4)

                    Repeater {
                        model: root.services

                        delegate: Item {
                            id: serviceRow

                            required property var modelData

                            width: content.width
                            implicitHeight: Math.max(statusMark.implicitHeight, serviceLabels.implicitHeight) + Style.space(8)

                            Text {
                                id: statusMark
                                anchors.left: parent.left
                                anchors.verticalCenter: parent.verticalCenter
                                width: Style.space(22)
                                horizontalAlignment: Text.AlignHCenter
                                text: root.serviceIcon(String(serviceRow.modelData.health || "unknown"))
                                color: root.serviceColor(String(serviceRow.modelData.health || "unknown"))
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.body
                                font.bold: true
                            }

                            Column {
                                id: serviceLabels
                                anchors.left: statusMark.right
                                anchors.leftMargin: Style.space(8)
                                anchors.right: serviceState.left
                                anchors.rightMargin: Style.space(10)
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: Style.space(1)

                                Text {
                                    width: parent.width
                                    text: String(serviceRow.modelData.name || "Service")
                                    color: root.foreground
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.body
                                    font.bold: true
                                    elide: Text.ElideRight
                                }

                                Text {
                                    width: parent.width
                                    text: String(serviceRow.modelData.detail || "")
                                    color: root.dim
                                    font.family: root.fontFamily
                                    font.pixelSize: Style.font.caption
                                    elide: Text.ElideRight
                                }
                            }

                            Text {
                                id: serviceState
                                anchors.right: parent.right
                                anchors.verticalCenter: parent.verticalCenter
                                text: root.serviceLabel(String(serviceRow.modelData.health || "unknown"))
                                color: root.serviceColor(String(serviceRow.modelData.health || "unknown"))
                                font.family: root.fontFamily
                                font.pixelSize: Style.font.caption
                                font.bold: true
                                font.letterSpacing: 0.8
                            }
                        }
                    }

                    Text {
                        visible: root.services.length === 0
                        width: parent.width
                        text: root.refreshError || "Loading the global status…"
                        color: root.refreshError !== "" ? root.urgent : root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.body
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        topPadding: Style.space(10)
                        bottomPadding: Style.space(10)
                    }
                }

                Text {
                    visible: root.refreshError !== "" && root.hasKnownStatus
                    width: parent.width
                    text: root.refreshError + "; showing the last known check."
                    color: root.urgent
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                }

                Row {
                    width: parent.width
                    spacing: Style.space(8)

                    Button {
                        width: (parent.width - parent.spacing) / 2
                        text: root.refreshState === "refreshed" ? "Refreshed!" : root.refreshState === "error" ? "Error" : "Refresh · R"
                        iconText: "↻"
                        iconSpinning: statusProcess.running
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        focusable: true
                        bordered: true
                        enabled: !statusProcess.running
                        onClicked: root.refresh(true)
                    }

                    Button {
                        width: (parent.width - parent.spacing) / 2
                        text: root.shareState === "copied" ? "Copied!" : root.shareState === "error" ? "Error" : "Share latest · S"
                        iconText: "󰁜"
                        foreground: root.foreground
                        fontFamily: root.fontFamily
                        focusable: true
                        bordered: true
                        onClicked: root.shareLatest(false)
                    }
                }
            }
        }
    }
}
