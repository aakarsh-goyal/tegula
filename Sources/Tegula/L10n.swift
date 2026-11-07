import Foundation

/// UI strings in English, Spanish, Japanese, Korean, Simplified Chinese (index order).
enum S: String {
    case grid, columns, rows, side, pause, tileApp, focus, focusOff, focusDim, focusNoPeek
    case cleanSpace, setups, saveSetup, noSetups, deleteSetup, retile, settings, quit, grantAccess, accessText, accessTitle
    case general, borders, behavior, shortcuts, about, mainSize, half, sixty, twoThirds, spacing, edgeSpace
    case top, bottom, left, right, theme, themeSystem, themeLight, themeDark, language, languageSystem
    case appIcon, launchAtLogin, borderStyle, borderNone, borderActive, borderAll, borderGlow, borderColor
    case tabView, hoverActivate, quickActions, excludedApps, noExcluded, remove, addApp, notSet, pressKeys
    case conflictTitle, conflictBody, useInstead, cancel, setupName, save, rename, reset, setupsHint
    case swapLeft, swapRight, swapUp, swapDown, makeMain, floatWin, closeWin, paused, aboutText
    case close, minimize, editMenu, cut, copy, paste, selectAll, windowMenu, animate, makeMainAction, setupSaved, slateIcon, clayIcon, layout, needMod, restartNote
}

enum L10n {
    static let langs: [(code: String, name: String)] = [
        ("en", "English"), ("es", "Español"), ("ja", "日本語"), ("ko", "한국어"), ("zh", "简体中文")]

    static var code: String {
        let pref = Settings.shared.language
        if pref != "system" { return pref }
        let first = Locale.preferredLanguages.first ?? "en"
        for l in langs where first.hasPrefix(l.code) { return l.code }
        return "en"
    }

    static func t(_ s: S) -> String {
        guard let row = table[s] else { return s.rawValue }
        let i = langs.firstIndex { $0.code == code } ?? 0
        return i < row.count ? row[i] : row[0]
    }

    private static let table: [S: [String]] = [
        .grid: ["Grid", "Cuadrícula", "グリッド", "격자", "网格"],
        .columns: ["Columns", "Columnas", "カラム", "열", "分栏"],
        .rows: ["Rows", "Filas", "行", "행", "分行"],
        .side: ["Side", "Lateral", "サイド", "사이드", "侧栏"],
        .layout: ["Layout", "Diseño", "レイアウト", "레이아웃", "布局"],
        .pause: ["Pause Tiling", "Pausar mosaico", "タイリングを一時停止", "타일링 일시 중지", "暂停平铺"],
        .paused: ["Paused", "En pausa", "一時停止中", "일시 중지됨", "已暂停"],
        .tileApp: ["Tile %@", "Mosaico para %@", "%@ をタイル表示", "%@ 타일링", "平铺 %@"],
        .focus: ["Focus", "Enfoque", "フォーカス", "포커스", "专注"],
        .focusOff: ["Off", "Desactivado", "オフ", "끄기", "关闭"],
        .focusDim: ["Dim Others", "Atenuar el resto", "他を暗くする", "나머지 어둡게", "调暗其他"],
        .focusNoPeek: ["No Peek", "Sin vistazos", "のぞき見なし", "엿보기 방지", "禁止窥视"],
        .cleanSpace: ["Clean Space", "Espacio limpio", "クリーンスペース", "클린 스페이스", "清理空间"],
        .setups: ["Setups", "Configuraciones", "セットアップ", "셋업", "场景"],
        .saveSetup: ["Save Current Setup…", "Guardar configuración actual…", "現在のセットアップを保存…", "현재 셋업 저장…", "保存当前场景…"],
        .noSetups: ["No saved setups", "Sin configuraciones guardadas", "保存済みなし", "저장된 셋업 없음", "没有已保存的场景"],
        .deleteSetup: ["Delete", "Eliminar", "削除", "삭제", "删除"],
        .retile: ["Retile All", "Reorganizar todo", "すべて再配置", "모두 다시 배치", "重新平铺全部"],
        .settings: ["Settings…", "Ajustes…", "設定…", "설정…", "设置…"],
        .quit: ["Quit Tegula", "Salir de Tegula", "Tegula を終了", "Tegula 종료", "退出 Tegula"],
        .grantAccess: ["Grant Accessibility Access…", "Conceder acceso de Accesibilidad…", "アクセシビリティを許可…", "손쉬운 사용 권한 허용…", "授予辅助功能权限…"],
        .accessTitle: ["Tegula needs Accessibility access", "Tegula necesita acceso de Accesibilidad", "Tegula にはアクセシビリティ権限が必要です", "Tegula에 손쉬운 사용 권한이 필요합니다", "Tegula 需要辅助功能权限"],
        .accessText: ["Tegula uses Accessibility only to move and resize windows. Enable it in System Settings › Privacy & Security › Accessibility, then Tegula starts tiling right away.",
                      "Tegula usa Accesibilidad solo para mover y cambiar el tamaño de las ventanas. Actívalo en Ajustes del Sistema › Privacidad y seguridad › Accesibilidad.",
                      "Tegula はウィンドウの移動とサイズ変更のためだけにアクセシビリティを使用します。システム設定 › プライバシーとセキュリティ › アクセシビリティで有効にしてください。",
                      "Tegula는 창을 이동하고 크기를 조절하는 데만 손쉬운 사용을 사용합니다. 시스템 설정 › 개인정보 보호 및 보안 › 손쉬운 사용에서 켜 주세요.",
                      "Tegula 仅使用辅助功能来移动和调整窗口大小。请在“系统设置 › 隐私与安全性 › 辅助功能”中启用。"],
        .general: ["General", "General", "一般", "일반", "通用"],
        .borders: ["Appearance", "Apariencia", "外観", "모양", "外观"],
        .behavior: ["Behavior", "Comportamiento", "動作", "동작", "行为"],
        .shortcuts: ["Shortcuts", "Atajos", "ショートカット", "단축키", "快捷键"],
        .about: ["About", "Acerca de", "情報", "정보", "关于"],
        .mainSize: ["Main window size", "Tamaño de la ventana principal", "メインウィンドウのサイズ", "메인 창 크기", "主窗口大小"],
        .half: ["Half", "Mitad", "1/2", "1/2", "一半"],
        .sixty: ["60%", "60 %", "60%", "60%", "60%"],
        .twoThirds: ["Two-thirds", "Dos tercios", "2/3", "2/3", "三分之二"],
        .spacing: ["Space between windows", "Espacio entre ventanas", "ウィンドウ間の余白", "창 사이 간격", "窗口间距"],
        .edgeSpace: ["Empty space along screen edges (for docks and bars)", "Espacio libre en los bordes (para docks y barras)", "画面端の空き（ドックやバー用）", "화면 가장자리 여백 (독/바용)", "屏幕边缘留白（用于 Dock 和状态栏）"],
        .top: ["Top", "Arriba", "上", "위", "上"],
        .bottom: ["Bottom", "Abajo", "下", "아래", "下"],
        .left: ["Left", "Izquierda", "左", "왼쪽", "左"],
        .right: ["Right", "Derecha", "右", "오른쪽", "右"],
        .theme: ["Theme", "Tema", "テーマ", "테마", "主题"],
        .themeSystem: ["Match system", "Como el sistema", "システムに合わせる", "시스템과 동일", "跟随系统"],
        .themeLight: ["Light", "Claro", "ライト", "라이트", "浅色"],
        .themeDark: ["Dark", "Oscuro", "ダーク", "다크", "深色"],
        .language: ["Language", "Idioma", "言語", "언어", "语言"],
        .languageSystem: ["Match system", "Como el sistema", "システムに合わせる", "시스템과 동일", "跟随系统"],
        .appIcon: ["App icon", "Icono de la app", "アプリアイコン", "앱 아이콘", "应用图标"],
        .slateIcon: ["Slate", "Pizarra", "スレート", "슬레이트", "石板"],
        .clayIcon: ["Clay", "Arcilla", "粘土", "점토", "陶土"],
        .launchAtLogin: ["Open at login", "Abrir al iniciar sesión", "ログイン時に開く", "로그인 시 열기", "登录时打开"],
        .borderStyle: ["Window borders", "Bordes de ventana", "ウィンドウの枠", "창 테두리", "窗口边框"],
        .borderNone: ["None", "Ninguno", "なし", "없음", "无"],
        .borderActive: ["Active border", "Borde activo", "アクティブ枠", "활성 테두리", "活动边框"],
        .borderAll: ["All borders", "Todos los bordes", "すべての枠", "모든 테두리", "全部边框"],
        .borderGlow: ["Glow", "Resplandor", "グロー", "글로우", "发光"],
        .borderColor: ["Border color", "Color del borde", "枠の色", "테두리 색상", "边框颜色"],
        .close: ["Close", "Cerrar", "閉じる", "닫기", "关闭"],
        .minimize: ["Minimize", "Minimizar", "しまう", "최소화", "最小化"],
        .editMenu: ["Edit", "Edición", "編集", "편집", "编辑"],
        .cut: ["Cut", "Cortar", "カット", "잘라내기", "剪切"],
        .copy: ["Copy", "Copiar", "コピー", "복사", "拷贝"],
        .paste: ["Paste", "Pegar", "ペースト", "붙여넣기", "粘贴"],
        .selectAll: ["Select All", "Seleccionar todo", "すべてを選択", "전체 선택", "全选"],
        .windowMenu: ["Window", "Ventana", "ウインドウ", "윈도우", "窗口"],
        .animate: ["Animate window movement", "Animar el movimiento de ventanas", "ウィンドウの移動をアニメーション表示", "창 이동 애니메이션", "窗口移动动画"],
        .tabView: ["Tab View for stacked windows", "Vista de pestañas para ventanas apiladas", "重なったウィンドウをタブ表示", "겹친 창 탭 보기", "为堆叠窗口显示标签页"],
        .hoverActivate: ["Activate windows on hover", "Activar ventanas al pasar el ratón", "ホバーでウィンドウをアクティブ化", "마우스 오버 시 창 활성화", "悬停时激活窗口"],
        .quickActions: ["Quick actions above windows", "Acciones rápidas sobre las ventanas", "ウィンドウ上のクイックアクション", "창 위 빠른 동작", "窗口上方的快捷操作"],
        .excludedApps: ["Apps that are never tiled", "Apps que nunca se organizan", "タイル表示しないアプリ", "타일링하지 않을 앱", "不平铺的应用"],
        .noExcluded: ["None", "Ninguna", "なし", "없음", "无"],
        .remove: ["Remove", "Quitar", "削除", "제거", "移除"],
        .addApp: ["Add App…", "Añadir app…", "アプリを追加…", "앱 추가…", "添加应用…"],
        .notSet: ["Not set", "Sin asignar", "未設定", "설정 안 됨", "未设置"],
        .pressKeys: ["Press keys…", "Pulsa las teclas…", "キーを押す…", "키를 누르세요…", "请按键…"],
        .conflictTitle: ["Shortcut already in use", "Atajo ya en uso", "ショートカットは使用中です", "이미 사용 중인 단축키", "快捷键已被占用"],
        .conflictBody: ["%@ is taken by macOS or another app.", "%@ ya lo usa macOS u otra app.", "%@ は macOS または他のアプリで使用されています。", "%@ 은(는) macOS 또는 다른 앱에서 사용 중입니다.", "%@ 已被 macOS 或其他应用使用。"],
        .useInstead: ["Use %@", "Usar %@", "%@ を使う", "%@ 사용", "使用 %@"],
        .cancel: ["Cancel", "Cancelar", "キャンセル", "취소", "取消"],
        .needMod: ["Include at least one modifier key (⌃ ⌥ ⇧ ⌘).", "Incluye al menos una tecla modificadora (⌃ ⌥ ⇧ ⌘).", "修飾キー（⌃ ⌥ ⇧ ⌘）を1つ以上含めてください。", "수정 키(⌃ ⌥ ⇧ ⌘)를 하나 이상 포함하세요.", "请至少包含一个修饰键（⌃ ⌥ ⇧ ⌘）。"],
        .setupName: ["Name this setup", "Nombre de la configuración", "セットアップの名前", "셋업 이름", "为场景命名"],
        .save: ["Save", "Guardar", "保存", "저장", "保存"],
        .rename: ["Rename", "Renombrar", "名前を変更", "이름 변경", "重命名"],
        .reset: ["Reset", "Restablecer", "リセット", "재설정", "重置"],
        .setupSaved: ["Saves apps and where they sit on each screen — not window titles or documents. Launching a setup hides every other app (nothing quits).",
                      "Guarda las apps y su posición en cada pantalla, no títulos ni documentos. Al lanzar una configuración se ocultan las demás apps (no se cierra ninguna).",
                      "アプリと各画面での配置のみを保存します（ウィンドウ名や書類は保存しません）。実行すると他のアプリは隠れます（終了はしません）。",
                      "앱과 각 화면에서의 위치만 저장합니다 (창 제목·문서는 저장 안 함). 실행하면 다른 앱은 숨겨집니다 (종료되지 않음).",
                      "仅保存应用及其在各屏幕上的位置，不保存窗口标题或文档。启动场景会隐藏其他应用（不会退出）。"],
        .setupsHint: ["Setups (beta)", "Configuraciones (beta)", "セットアップ（ベータ）", "셋업 (베타)", "场景（测试版）"],
        .swapLeft: ["Swap with left", "Intercambiar con la izquierda", "左と入れ替え", "왼쪽과 교체", "与左侧交换"],
        .swapRight: ["Swap with right", "Intercambiar con la derecha", "右と入れ替え", "오른쪽과 교체", "与右侧交换"],
        .swapUp: ["Swap with above", "Intercambiar con la de arriba", "上と入れ替え", "위와 교체", "与上方交换"],
        .swapDown: ["Swap with below", "Intercambiar con la de abajo", "下と入れ替え", "아래와 교체", "与下方交换"],
        .makeMain: ["Make main window", "Hacer ventana principal", "メインにする", "메인 창으로 만들기", "设为主窗口"],
        .makeMainAction: ["Make main window", "Hacer ventana principal", "メインにする", "메인 창으로 만들기", "设为主窗口"],
        .floatWin: ["Float window", "Liberar ventana", "フロートにする", "창 띄우기", "浮动窗口"],
        .closeWin: ["Close window", "Cerrar ventana", "ウィンドウを閉じる", "창 닫기", "关闭窗口"],
        .restartNote: ["Icon changes apply instantly.", "El icono cambia al instante.", "アイコンはすぐに反映されます。", "아이콘은 즉시 적용됩니다.", "图标立即生效。"],
        .aboutText: ["Tegula tiles your windows automatically.\nIt works offline, logs no keystrokes, takes no screenshots and never reads window contents. Accessibility access is used only to move and resize windows.",
                     "Tegula organiza tus ventanas automáticamente.\nFunciona sin conexión, no registra pulsaciones, no hace capturas y nunca lee el contenido de las ventanas.",
                     "Tegula はウィンドウを自動で整列します。\nオフラインで動作し、キー入力の記録・スクリーンショット・ウィンドウ内容の読み取りは一切行いません。",
                     "Tegula는 창을 자동으로 정렬합니다.\n오프라인으로 작동하며 키 입력을 기록하거나 스크린샷을 찍거나 창 내용을 읽지 않습니다.",
                     "Tegula 自动平铺你的窗口。\n完全离线运行，不记录按键、不截屏，也不读取窗口内容。"],
    ]
}
