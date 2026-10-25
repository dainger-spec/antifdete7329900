import Foundation

/// What a line of `vm/controller/tart-prototype.sh` output means for the UI.
public enum ScriptEvent: Equatable, Sendable {
    /// A new step began (`==> …` lines).
    case stage(LaunchStage, detail: String)
    /// More detail for a step that is already running.
    case detail(LaunchStage, String)
    /// Safari was pointed at the URL; the script now waits for the VM to exit.
    case ready(ip: String?)
    /// The script's cleanup started stopping the VM.
    case stopping
    /// A failure the script reported, as a user-facing (Russian) message.
    case error(String)
}

/// Maps the bash prototype's human-readable output onto launch stages, so the
/// app can drive the tested script instead of reimplementing it.
///
/// Keyed on the script's own `echo` texts. ScriptOutputParserTests reads the
/// script and fails if an `==> ` line is neither mapped nor listed as ignored,
/// so a wording change there can't silently stall the progress display.
public struct ScriptOutputParser: Sendable {
    struct StageRule: Sendable {
        let prefix: String
        let stage: LaunchStage
        let detail: @Sendable (String) -> String
    }

    static let stageRules: [StageRule] = [
        StageRule(prefix: "Checking VM", stage: .vm) { _ in "Проверка VM…" },
        StageRule(prefix: "Starting VM", stage: .vm) { _ in "Запуск VM…" },
        StageRule(prefix: "Waiting for VM IP", stage: .vm) { _ in "Ожидание IP-адреса VM…" },
        StageRule(prefix: "Waiting for SSH", stage: .vm) { _ in "Ожидание SSH…" },
        StageRule(prefix: "Setting hardware identity", stage: .vm) { _ in "Настройка имени хоста VM…" },
        StageRule(prefix: "Configuring proxy in the VM", stage: .vm) { _ in "Настройка прокси в VM…" },
        StageRule(prefix: "Preparing the browser window", stage: .vm) { _ in "Подготовка окна браузера…" },
        StageRule(prefix: "Installing in-VM agent", stage: .agent) { _ in "Копирование и установка агента…" },
        StageRule(prefix: "Opening SSH tunnel", stage: .agent) { _ in "Открытие SSH-туннеля…" },
        StageRule(prefix: "Waiting for agent", stage: .agent) { _ in "Ожидание ответа агента…" },
        StageRule(prefix: "Navigating Safari to ", stage: .safari) { body in
            "Открытие \(body.dropFirst("Navigating Safari to ".count))…"
        },
    ]

    /// `==> ` lines that carry no stage change.
    static let ignoredHeadings = ["Status:", "Saving screenshot"]

    struct ErrorRule: Sendable {
        let prefix: String
        let message: String
    }

    static let errorRules: [ErrorRule] = [
        ErrorRule(prefix: "tart run exited before the VM got an IP",
                  message: "VM не запустилась: tart run сразу завершился (его ошибка — в журнале). Частые причины: "
                      + "эта VM уже запущена, уже работают две macOS-VM (ограничение Apple), не стартовал softnet."),
        ErrorRule(prefix: "Failed to get VM IP",
                  message: "VM не получила IP-адрес за отведённое время. Подробности — в журнале; "
                      + "чтобы увидеть, загрузилась ли macOS, включите «Показывать окно VM»."),
        ErrorRule(prefix: "softnet needs root",
                  message: "softnet нужны права root. Один раз выполните в Терминале команду из журнала "
                      + "(sudo sh -c 'chown root … && chmod u+s …') и запустите профиль снова."),
        ErrorRule(prefix: "fail-closed networking needs a newer",
                  message: "Для сети «только через прокси» нужны tart ≥ 2.30 и softnet ≥ 0.22: "
                      + "brew upgrade cirruslabs/cli/tart cirruslabs/cli/softnet"),
        ErrorRule(prefix: "Could not configure the proxy in the VM",
                  message: "Не удалось настроить прокси в VM (см. журнал). Без него VM профиля не выходит в сеть."),
        ErrorRule(prefix: "softnet not found",
                  message: "Для профиля нужен softnet (сеть только через прокси): brew install cirruslabs/cli/softnet"),
        ErrorRule(prefix: "SSH did not come up",
                  message: "Не удалось подключиться к VM по SSH. В образе Cirrus Labs логин admin, пароль admin; "
                      + "в VM должен быть включён «Удалённый вход»."),
        ErrorRule(prefix: "Could not read agent token",
                  message: "Установка агента в VM не вернула токен (см. журнал)."),
        ErrorRule(prefix: "Agent did not respond",
                  message: "Агент в VM не отвечает через SSH-туннель."),
        ErrorRule(prefix: "VM not found",
                  message: "VM не найдена — сначала нужно склонировать образ."),
        ErrorRule(prefix: "TART_NET must be",
                  message: "Неверное значение TART_NET (нужно bridged или shared)."),
    ]

    static let requiredTools: Set<String> = ["tart", "ssh", "scp", "curl"]

    public private(set) var vmIP: String?

    public init() {}

    /// "still waiting for VM IP (30s of 120s, …)" → (30, 120).
    static func ipWait(_ line: String) -> (elapsed: Int, limit: Int)? {
        let prefix = "still waiting for VM IP ("
        guard line.hasPrefix(prefix) else { return nil }
        let numbers = line.dropFirst(prefix.count).split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
        return numbers.count == 2 ? (numbers[0], numbers[1]) : nil
    }

    public mutating func consume(_ rawLine: String) -> ScriptEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("==> ") {
            let body = String(line.dropFirst(4))
            if let rule = Self.stageRules.first(where: { body.hasPrefix($0.prefix) }) {
                return .stage(rule.stage, detail: rule.detail(body))
            }
            if body.hasPrefix("Stopping VM") { return .stopping }
            return nil
        }
        if let waited = Self.ipWait(line) {
            return .detail(.vm, "Ожидание IP-адреса VM: \(waited.elapsed) из \(waited.limit) с…")
        }
        if line.hasPrefix("VM IP: ") {
            let ip = String(line.dropFirst("VM IP: ".count))
            vmIP = ip
            return .detail(.vm, "IP-адрес VM: \(ip)")
        }
        if line == "agent installed; token captured" {
            return .detail(.agent, "Агент установлен")
        }
        if line.hasPrefix("VM is up at") {
            return .ready(ip: vmIP)
        }
        if let rule = Self.errorRules.first(where: { line.hasPrefix($0.prefix) }) {
            return .error(rule.message)
        }
        if line.hasSuffix(" not found"), Self.requiredTools.contains(String(line.dropLast(" not found".count))) {
            return .error("На Mac не найдена программа «\(line.dropLast(" not found".count))».")
        }
        if line.hasPrefix("curl: (") {
            return .error("Запрос к агенту в VM не удался: \(line)")
        }
        return nil
    }
}
