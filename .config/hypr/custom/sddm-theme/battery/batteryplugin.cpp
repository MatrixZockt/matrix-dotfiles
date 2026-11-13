// ── The login screen's battery, as a Qt Quick plugin ─────────────────────────
//
// WHY THIS IS C++ AND NOT QML
//
// The greeter is a QML engine and nothing else: `sddm-greeter-qt6` is started
// with a deliberately built environment (src/daemon/Greeter.cpp copies only
// LANG/LC_*, LD_LIBRARY_PATH, QML2_IMPORT_PATH, QT_PLUGIN_PATH and
// XDG_DATA_DIRS from the daemon), and QML itself refuses to open a local file
// unless QML_XHR_ALLOW_FILE_READ is set -- a variable that cannot reach the
// greeter that way, and there is no other channel: no Process, no File type,
// and the theme config is read once at startup so a value baked into it goes
// stale while the machine sits at the login screen.
//
// So the read happens in C++, where opening /sys/class/power_supply/BAT0 is
// three lines, and QML gets it as an ordinary singleton property. The greeter
// already loads QML plugins from the theme directory (its QML2_IMPORT_PATH is
// inherited from the daemon), and `import "battery"` in BatteryReadout.qml is
// a LOCAL directory import resolved next to the QML file -- no import path of
// any kind has to be configured, and nothing outside the theme is touched.
//
// It is deliberately isolated: BatteryReadout.qml is loaded through a Loader,
// so a missing or mismatched plugin fails inside that one hidden item and the
// login screen still draws. A login screen must never depend on a readout.
//
// Built by install-sddm-theme.sh (see there); not part of the running shell.

#include <QtCore/QDir>
#include <QtCore/QFile>
#include <QtCore/QObject>
#include <QtCore/QTimer>
#include <QtCore/QtPlugin>
#include <QtQml/QQmlEngine>
#include <QtQml/QQmlExtensionPlugin>

namespace {

QString readLine(const QString &path)
{
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return QString();
    return QString::fromLatin1(file.readAll()).trimmed();
}

// The first BAT* node that carries a capacity. Resolved at runtime rather than
// hardcoded to BAT0 for the same reason the shell's Battery service resolves
// it: the pack is BAT0 on this machine and BAT1 on plenty of others, and a
// hardcoded name fails silently -- the readout would simply be absent.
QString batteryDir()
{
    const QStringList names = QDir(QStringLiteral("/sys/class/power_supply"))
                                  .entryList(QStringList() << QStringLiteral("BAT*"), QDir::Dirs);
    for (const QString &name : names) {
        const QString path = QStringLiteral("/sys/class/power_supply/") + name;
        if (QFile::exists(path + QStringLiteral("/capacity")))
            return path;
    }
    return QString();
}

} // namespace

class IosBattery : public QObject
{
    Q_OBJECT
    Q_PROPERTY(int percent READ percent NOTIFY changed)
    Q_PROPERTY(bool present READ present NOTIFY changed)
    Q_PROPERTY(bool charging READ charging NOTIFY changed)
    Q_PROPERTY(bool onAc READ onAc NOTIFY changed)
    Q_PROPERTY(QString status READ status NOTIFY changed)

public:
    explicit IosBattery(QObject *parent = nullptr) : QObject(parent)
    {
        // Twenty seconds: sysfs is free to read, and a battery percentage that
        // is at most 20 s old is indistinguishable from a live one at a login
        // screen. `changed` only fires on an actual change, so the QML binding
        // is not re-evaluated on every tick.
        m_timer.setInterval(20000);
        connect(&m_timer, &QTimer::timeout, this, &IosBattery::refresh);
        m_timer.start();
        reload();
    }

    // -1 when there is no battery: the QML side hides the row on `present`.
    int percent() const { return m_percent; }
    bool present() const { return m_percent >= 0; }
    bool charging() const { return m_status == QLatin1String("Charging"); }
    // "Not charging" is what a pack held at its charge cap reports while the
    // charger is in, so only "Discharging" means the machine is eating it.
    bool onAc() const { return m_percent >= 0 && m_status != QLatin1String("Discharging"); }
    QString status() const { return m_status; }

public Q_SLOTS:
    void refresh() { reload(); }

Q_SIGNALS:
    void changed();

private:
    void reload()
    {
        const QString dir = batteryDir();
        int percent = -1;
        QString status;
        if (!dir.isEmpty()) {
            bool ok = false;
            percent = readLine(dir + QStringLiteral("/capacity")).toInt(&ok);
            if (!ok)
                percent = -1;
            status = readLine(dir + QStringLiteral("/status"));
        }
        if (percent == m_percent && status == m_status)
            return;
        m_percent = percent;
        m_status = status;
        Q_EMIT changed();
    }

    QTimer m_timer;
    int m_percent = -1;
    QString m_status;
};

class IosBatteryPlugin : public QQmlExtensionPlugin
{
    Q_OBJECT
    // Writ as a string, not as the QQmlExtensionInterface_iid macro: the Qt 6.12
    // moc on this machine parses the literal form and rejects the macro one
    // ("Parse error at IID"). The string is what the macro expands to, and it
    // is what the plugin loader compares against.
    Q_PLUGIN_METADATA(IID "org.qt-project.Qt.QQmlExtensionInterface/1.0")
public:
    void registerTypes(const char *uri) override
    {
        qmlRegisterSingletonType<IosBattery>(uri, 1, 0, "Battery",
            [](QQmlEngine *, QJSEngine *) -> QObject * { return new IosBattery; });
    }
};

#include "batteryplugin.moc"
