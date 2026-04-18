public class MySettings : GLib.Object {
    private int _v = 0;
    public int v {
        get { return _v; }
        set { _v = value; }
    }
}
void main() {
    var m = new MySettings();
    m.notify["v"].connect(() => {
        GLib.message("v changed!");
    });
    m.v = 1;
}
