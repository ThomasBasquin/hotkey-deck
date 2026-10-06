# Deck — "Stream Deck" à l'écran, chargé par hotkey_deck.ps1 (dot-source)
#
# La touche ² (AZERTY, à gauche de 1) ouvre une grille de
# boutons au centre de l'écran du jeu / de la fenêtre active ; clic, ou touches
# 1-9, pour lancer une action. Échap, ² ou un clic ailleurs referme.
#
# Compatible anti-cheat, comme le reste du script :
#   - touche ² réservée via RegisterHotKey (Windows l'avale : elle ne tape
#     plus de ²), pas de hook clavier bas niveau
#   - températures lues dans la mémoire partagée d'Afterburner, état du GPU via
#     NVML (lecture seule) : aucun pilote ni accès matériel de notre côté
#   - seule entrée simulée : Alt+F10 pour l'Instant Replay NVIDIA (pas d'API),
#     envoyée pendant que le deck a le focus, donc jamais reçue par le jeu
#
# Plein écran : par-dessus les jeux en fenêtré sans bordure / DX12 (cas
# courant). Un jeu en plein écran exclusif ne laisse rien s'afficher
# par-dessus : le deck s'ouvre alors sur l'autre écran.

# (PowerShell ignore la casse des variables : ne pas nommer ceci $Deck, ce
# serait la même variable que la fenêtre $deck, qui l'écraserait)
$DeckCfg = @{
    Afterburner  = 'C:\Program Files (x86)\MSI Afterburner\MSIAfterburner.exe'
    ProfileStock = 1     # profils Afterburner (Profile1.cfg / Profile2.cfg)
    ProfileOC    = 2
    ReplayKeys   = @(0xA4, 0x79)   # Alt gauche + F10 (sauvegarde Instant Replay)
    # Alerte OSD si le CPU ou le GPU reste au-dessus de TempAlert (°C) pendant
    # TempSustain relevés de suite (un toutes les TempCheckMs) ; nouvelle
    # alerte seulement après être redescendu sous TempReset
    TempAlert    = 67
    TempReset    = 64
    TempSustain  = 2
    TempCheckMs  = 5000
    # Bandeau d'alerte permanent si un ventilateur du GPU dépasse FanMax (%)
    # pendant TempSustain relevés de suite (ventilateurs fixés à 35 % dans Afterburner)
    FanMax       = 35
}

Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing, System.Core -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.IO.MemoryMappedFiles;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace HotkeyDeck {
    public class Tile {
        public string Id, Glyph = "", Title = "", Sub = "";
        public Color Accent = Color.FromArgb(0x4C, 0xC2, 0xFF);
        public bool On;              // état actif : carte « allumée » (teintée de la couleur d'accent)
        public bool Clickable = true;
        public int Col, Row;         // place dans la grille de boutons ; Row = -1 : barre d'état
        public string Value = "";    // barre d'état : valeur affichée après le titre
    }

    public class DeckForm : Form {
        [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
        [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
        [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, IntPtr pid);
        [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
        [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
        [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
        [DllImport("user32.dll")] static extern bool AttachThreadInput(uint a, uint b, bool attach);
        [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
        [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(Point p, uint f);
        [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr mon, int type, out uint x, out uint y);
        [DllImport("shell32.dll")] static extern int SHQueryUserNotificationState(out int state);
        [DllImport("dwmapi.dll")] static extern int DwmSetWindowAttribute(IntPtr h, int a, ref int v, int s);

        // Dimensions en pixels à 100 % : carte, écart entre cartes d'une colonne,
        // entre colonnes, marge, titres de colonnes, barre d'état
        const int TW = 160, TH = 128, GAP = 12, COLGAP = 22, PAD = 18, HEAD = 30, BAR = 54;

        public List<Tile> Tiles = new List<Tile>();
        public string[] Headers = new string[0];   // titres des colonnes de boutons
        public event Action<string> TileClicked;
        public event Action<string> Info;   // historique (journal) : fermetures, focus perdu
        public bool Exclusive;        // plein écran exclusif détecté au dernier affichage
        int shownAt;
        int regrabs;   // reprises du focus depuis l'ouverture
        string fgMethod = "";

        readonly List<Rectangle> rects = new List<Rectangle>();
        Rectangle barRect;
        readonly Timer fade = new Timer { Interval = 15 };
        IntPtr prevFg;
        float scale = 1f;
        int hover = -1, pressed = -1;
        Font fGlyph, fTitle, fSub, fHead, fBarLabel, fBarValue, fBarGlyph, fIndex;

        public DeckForm() {
            FormBorderStyle = FormBorderStyle.None;
            ShowInTaskbar = false;
            StartPosition = FormStartPosition.Manual;
            KeyPreview = true;
            TopMost = true;
            BackColor = Color.FromArgb(0x1C, 0x1C, 0x1C);
            SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
            fade.Tick += (s, e) => {
                double o = Opacity + 0.25;
                if (o >= 0.97) { o = 0.97; fade.Stop(); }
                Opacity = o;
            };
        }

        protected override CreateParams CreateParams {
            get {
                var cp = base.CreateParams;
                cp.ExStyle |= 0x00000008 | 0x00000080;   // TOPMOST | TOOLWINDOW (absent d'Alt+Tab)
                return cp;
            }
        }

        protected override void OnHandleCreated(EventArgs e) {
            base.OnHandleCreated(e);
            int v = 2;   // coins arrondis Windows 11
            DwmSetWindowAttribute(Handle, 33, ref v, 4);
        }

        protected override void WndProc(ref Message m) {
            // Taille et polices sont calculées pour l'écran cible : on ignore le
            // redimensionnement automatique au passage sur un écran d'autre DPI
            if (m.Msg == 0x02E0 /* WM_DPICHANGED */) { m.Result = IntPtr.Zero; return; }
            // WM_ACTIVATE directement : l'événement Deactivate de WinForms ne se
            // déclenche pas quand le premier plan a été pris via AttachThreadInput
            if (m.Msg == 0x0006 /* WM_ACTIVATE */ && Visible && (m.WParam.ToInt64() & 0xFFFF) == 0 /* WA_INACTIVE */)
                BeginInvoke(new Action(() => OnFocusLost(true)));
            base.WndProc(ref m);
        }

        // Filet de sécurité appelé chaque seconde : le clic est déjà relâché à ce
        // moment-là, donc on ne reprend jamais le focus d'ici (il pourrait s'agir
        // d'un clic voulu ailleurs) ; seuls Alt / Windows encore enfoncés ferment
        public void FocusLost() { OnFocusLost(false); }

        static bool Down(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

        // Le deck n'a plus le premier plan (WM_ACTIVATE, reçu au moment même) :
        //  - changement voulu (clic hors du deck, Alt+Tab, touche Windows) : on ferme
        //  - fenêtre qui reprend le focus d'elle-même (constaté avec Chrome, et
        //    possible avec un jeu) : on reste affiché et on le reprend, au plus
        //    3 fois par ouverture pour ne pas se battre avec elle
        void OnFocusLost(bool live) {
            if (!Visible || HasFocus) return;
            string who = DescribeForeground();
            bool click = (Down(0x01) || Down(0x02) || Down(0x04)) && !Bounds.Contains(Cursor.Position);
            if (click || Down(0x12 /* Alt */) || Down(0x5B) || Down(0x5C) /* Windows */) {
                HideDeck(false, "changement de fenêtre → " + who);   // on laisse le focus à cette fenêtre
                return;
            }
            if (!live || regrabs >= 3) return;
            regrabs++;
            ForceForeground();
            Say("focus pris par " + who + " sans action de ta part, repris (" + regrabs + "/3, " + fgMethod + (HasFocus ? "" : ", ÉCHEC") + ")");
        }

        int Px(double v) { return (int)Math.Round(v * scale); }
        // Contenu des cartes : cotes d'origine (carte de 112 de haut) mises à l'échelle de TH
        int Pu(double v) { return Px(v * TH / 112.0); }

        // Numéro clavier (1-9) des tuiles cliquables, dans l'ordre d'affichage ; 0 = aucun
        int KeyNumber(int i) {
            if (!Tiles[i].Clickable) return 0;
            int n = 0;
            for (int k = 0; k <= i; k++) if (Tiles[k].Clickable) n++;
            return n <= 9 ? n : 0;
        }

        // Écran de la fenêtre active, ou un autre si elle est en plein écran exclusif
        Screen PickScreen(IntPtr fg) {
            Screen s = fg != IntPtr.Zero ? Screen.FromHandle(fg) : Screen.FromPoint(Cursor.Position);
            int st;
            Exclusive = SHQueryUserNotificationState(out st) == 0 && st == 3 /* QUNS_RUNNING_D3D_FULL_SCREEN */;
            if (Exclusive)
                foreach (var o in Screen.AllScreens)
                    if (!o.Bounds.Equals(s.Bounds)) return o;
            return s;
        }

        void BuildFonts() {
            foreach (var f in new[] { fGlyph, fTitle, fSub, fHead, fBarLabel, fBarValue, fBarGlyph, fIndex }) if (f != null) f.Dispose();
            fGlyph    = new Font("Segoe Fluent Icons", Pu(30), GraphicsUnit.Pixel);
            fTitle    = new Font("Segoe UI Semibold", Pu(14), GraphicsUnit.Pixel);
            fSub      = new Font("Segoe UI", Pu(11.5), GraphicsUnit.Pixel);
            fHead     = new Font("Segoe UI Semibold", Pu(11), GraphicsUnit.Pixel);
            fBarLabel = new Font("Segoe UI", Pu(12.5), GraphicsUnit.Pixel);
            fBarValue = new Font("Segoe UI Semibold", Pu(16), GraphicsUnit.Pixel);
            fBarGlyph = new Font("Segoe Fluent Icons", Pu(17), GraphicsUnit.Pixel);
            fIndex    = new Font("Segoe UI", Pu(10), GraphicsUnit.Pixel);
        }

        // Boutons placés par (Col, Row) sous les titres de colonnes ; les
        // tuiles Row = -1 se partagent la barre d'état en bas, à parts égales
        Size LayoutTiles() {
            rects.Clear();
            int cols = 1, rows = 1, nbar = 0;
            foreach (var t in Tiles) {
                if (t.Row < 0) { nbar++; continue; }
                cols = Math.Max(cols, t.Col + 1);
                rows = Math.Max(rows, t.Row + 1);
            }
            int top = PAD + (Headers.Length > 0 ? HEAD : 0);
            int w = 2 * PAD + cols * TW + (cols - 1) * COLGAP;
            int gridBottom = top + rows * TH + (rows - 1) * GAP;
            int barTop = gridBottom + 16;
            barRect = new Rectangle(Px(PAD), Px(barTop), Px(w - 2 * PAD), Px(BAR));
            int k = 0;
            foreach (var t in Tiles) {
                if (t.Row >= 0)
                    rects.Add(new Rectangle(Px(PAD + t.Col * (TW + COLGAP)), Px(top + t.Row * (TH + GAP)), Px(TW), Px(TH)));
                else {
                    rects.Add(new Rectangle(barRect.X + barRect.Width * k / nbar, barRect.Y, barRect.Width / nbar, barRect.Height));
                    k++;
                }
            }
            return new Size(Px(w), Px(barTop + (nbar > 0 ? BAR : 0) + PAD));
        }

        // Processus d'une fenêtre, pour le journal (pas le titre : il peut
        // contenir des données personnelles, ex. une recherche web)
        public static string Describe(IntPtr h) {
            if (h == IntPtr.Zero) return "(aucune)";
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            try { return System.Diagnostics.Process.GetProcessById((int)pid).ProcessName; } catch { return "?"; }
        }
        public static string DescribeForeground() { return Describe(GetForegroundWindow()); }
        public bool HasFocus { get { return GetForegroundWindow() == Handle; } }

        void Say(string m) { var h = Info; if (h != null) h(m); }

        // Renvoie le résultat de l'ouverture pour le journal
        public string ShowDeck() {
            prevFg = GetForegroundWindow();
            if (prevFg == Handle) prevFg = IntPtr.Zero;
            var scr = PickScreen(prevFg).Bounds;
            uint dx, dy;
            var mon = MonitorFromPoint(new Point(scr.X + scr.Width / 2, scr.Y + scr.Height / 2), 2);
            scale = GetDpiForMonitor(mon, 0, out dx, out dy) == 0 ? dx / 96f : 1f;
            BuildFonts();
            var sz = LayoutTiles();
            hover = pressed = -1;

            Opacity = 0;
            if (!Visible) Show();
            SetWindowPos(Handle, new IntPtr(-1), scr.X + (scr.Width - sz.Width) / 2, scr.Y + (scr.Height - sz.Height) / 2,
                         sz.Width, sz.Height, 0x0040 /* SWP_SHOWWINDOW */);
            shownAt = Environment.TickCount;
            regrabs = 0;
            ForceForeground();
            Invalidate();
            fade.Start();
            return (GetForegroundWindow() == Handle ? "au premier plan (" + fgMethod + ")" : "SANS le premier plan (actif : " + DescribeForeground() + ")")
                 + (Exclusive ? ", plein écran exclusif → autre écran" : "")
                 + ", " + scr.Width + "x" + scr.Height + " à " + (int)(scale * 100) + " %";
        }

        // Windows refuse le premier plan à une appli en arrière-plan : on
        // s'attache brièvement à la file d'entrée de la fenêtre active. Il faut
        // le focus pour que le jeu libère et réaffiche le curseur.
        void ForceForeground() {
            // Après un vrai appui sur le raccourci (WM_HOTKEY), Windows nous
            // autorise déjà le premier plan : l'appel simple suffit. L'attache
            // d'entrée laisse sinon l'activation dans un état incohérent (la
            // fenêtre précédente reprend la main ~1 s plus tard, sans
            // WM_ACTIVATE pour le deck) : on ne s'en sert qu'en secours.
            BringWindowToTop(Handle);
            if (SetForegroundWindow(Handle) && GetForegroundWindow() == Handle) { Activate(); fgMethod = "direct"; return; }
            fgMethod = "secours";
            IntPtr fg = GetForegroundWindow();
            uint ft = fg != IntPtr.Zero ? GetWindowThreadProcessId(fg, IntPtr.Zero) : 0, me = GetCurrentThreadId();
            bool att = ft != 0 && ft != me && AttachThreadInput(me, ft, true);
            try {
                BringWindowToTop(Handle);
                SetForegroundWindow(Handle);
                Activate();
            } finally {
                if (att) AttachThreadInput(me, ft, false);
            }
        }

        // restore : rend le focus à la fenêtre d'avant (le jeu)
        public void HideDeck(bool restore) { HideDeck(restore, "action"); }
        public void HideDeck(bool restore, string reason) {
            if (!Visible) return;
            fade.Stop();
            Hide();
            Say("fermé (" + reason + ") après " + (Environment.TickCount - shownAt) + " ms");
            if (restore && prevFg != IntPtr.Zero && IsWindow(prevFg)) SetForegroundWindow(prevFg);
        }

        protected override void OnKeyDown(KeyEventArgs e) {
            if (e.KeyCode == Keys.Escape) { HideDeck(true, "Échap"); return; }
            int n = 0;
            if (e.KeyCode >= Keys.D1 && e.KeyCode <= Keys.D9) n = e.KeyCode - Keys.D1 + 1;
            else if (e.KeyCode >= Keys.NumPad1 && e.KeyCode <= Keys.NumPad9) n = e.KeyCode - Keys.NumPad1 + 1;
            if (n == 0) return;
            for (int i = 0; i < Tiles.Count; i++) if (KeyNumber(i) == n) { Fire(i); return; }
        }

        void Fire(int i) {
            if (!Tiles[i].Clickable) return;
            var h = TileClicked;
            if (h != null) h(Tiles[i].Id);
        }

        int HitTest(Point p) {
            for (int i = 0; i < rects.Count; i++) if (rects[i].Contains(p)) return i;
            return -1;
        }

        protected override void OnMouseMove(MouseEventArgs e) {
            int h = HitTest(e.Location);
            if (h != hover) { hover = h; Cursor = h >= 0 && Tiles[h].Clickable ? Cursors.Hand : Cursors.Default; Invalidate(); }
        }
        protected override void OnMouseLeave(EventArgs e) { hover = -1; Invalidate(); }
        protected override void OnMouseDown(MouseEventArgs e) {
            if (e.Button == MouseButtons.Left) { pressed = HitTest(e.Location); Invalidate(); }
        }
        protected override void OnMouseUp(MouseEventArgs e) {
            int p = pressed;
            pressed = -1;
            Invalidate();
            if (e.Button == MouseButtons.Left && p >= 0 && p == HitTest(e.Location)) Fire(p);
        }

        static Color Mix(Color a, Color b, double t) {
            return Color.FromArgb((int)(a.R + (b.R - a.R) * t), (int)(a.G + (b.G - a.G) * t), (int)(a.B + (b.B - a.B) * t));
        }

        static GraphicsPath Round(Rectangle r, int rad) {
            var p = new GraphicsPath();
            int d = rad * 2;
            p.AddArc(r.X, r.Y, d, d, 180, 90);
            p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
            p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure();
            return p;
        }

        static Color TempColor(string v) {
            double t;
            string num = v.TrimEnd('°', ' ', 'C');
            if (!double.TryParse(num, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out t))
                return Color.FromArgb(0x9A, 0x9A, 0x9A);
            if (t >= 85) return Color.FromArgb(0xF8, 0x51, 0x49);
            if (t >= 70) return Color.FromArgb(0xFF, 0xA6, 0x4D);
            return Color.White;
        }

        // Élément de la barre d'état, centré : [icône] Titre Valeur
        // (valeur en couleur d'accent, ou selon la température si elle finit par °)
        void DrawStatus(Graphics g, Tile t, Rectangle r, Color grey) {
            var fmt = StringFormat.GenericTypographic;
            float gw = string.IsNullOrEmpty(t.Glyph) ? 0 : g.MeasureString(t.Glyph, fBarGlyph, 1000, fmt).Width + Pu(6);
            float lw = g.MeasureString(t.Title, fBarLabel, 1000, fmt).Width + Pu(6);
            float vw = g.MeasureString(t.Value, fBarValue, 1000, fmt).Width;
            float x = r.X + (r.Width - gw - lw - vw) / 2, cy = r.Y + r.Height / 2f;
            Color vc = t.Value.EndsWith("°") ? TempColor(t.Value) : t.Accent;
            if (gw > 0)
                using (var b = new SolidBrush(t.Accent))
                    g.DrawString(t.Glyph, fBarGlyph, b, x, cy - fBarGlyph.GetHeight(g) / 2, fmt);
            using (var b = new SolidBrush(grey))
                g.DrawString(t.Title, fBarLabel, b, x + gw, cy - fBarLabel.GetHeight(g) / 2, fmt);
            using (var b = new SolidBrush(vc))
                g.DrawString(t.Value, fBarValue, b, x + gw + lw, cy - fBarValue.GetHeight(g) / 2, fmt);
        }

        protected override void OnPaint(PaintEventArgs e) {
            var g = e.Graphics;
            g.Clear(BackColor);
            if (fTitle == null) return;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            var center = new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center, Trimming = StringTrimming.EllipsisCharacter, FormatFlags = StringFormatFlags.NoWrap };
            var baseBg = Color.FromArgb(0x2B, 0x2B, 0x2B);
            var grey = Color.FromArgb(0x9A, 0x9A, 0x9A);

            // Titres des colonnes (SON, ÉCRAN, JEU)
            using (var b = new SolidBrush(Color.FromArgb(0x80, 0x80, 0x80)))
                for (int c = 0; c < Headers.Length; c++)
                    g.DrawString(Headers[c], fHead, b, new RectangleF(Px(PAD + c * (TW + COLGAP)), Px(PAD), Px(TW), Px(HEAD - 8)), center);

            // Barre d'état : séparée des boutons par un trait, sans cartes
            if (barRect.Height > 0)
                using (var pen = new Pen(Color.FromArgb(0x38, 0x38, 0x38), Math.Max(1, Px(1))))
                    g.DrawLine(pen, barRect.X, barRect.Y - Px(8), barRect.Right, barRect.Y - Px(8));

            for (int i = 0; i < Tiles.Count && i < rects.Count; i++) {
                var t = Tiles[i];
                var r = rects[i];

                if (t.Row < 0) { DrawStatus(g, t, r, grey); continue; }

                Color bg = t.On ? Mix(baseBg, t.Accent, 0.28) : baseBg;
                if (t.Clickable && i == hover) bg = Mix(bg, Color.White, i == pressed ? 0.03 : 0.08);
                using (var path = Round(r, Pu(10)))
                using (var br = new SolidBrush(bg)) {
                    g.FillPath(br, path);
                    if (t.On) using (var pen = new Pen(Mix(bg, t.Accent, 0.6), Pu(1.5))) g.DrawPath(pen, path);
                }

                // Sans sous-titre, icône et titre sont recentrés verticalement
                int dy = string.IsNullOrEmpty(t.Sub) ? Pu(9) : 0;
                using (var b = new SolidBrush(t.Accent))
                    g.DrawString(t.Glyph, fGlyph, b, new RectangleF(r.X, r.Y + Pu(14) + dy, r.Width, Pu(44)), center);
                using (var b = new SolidBrush(Color.White))
                    g.DrawString(t.Title, fTitle, b, new RectangleF(r.X + Pu(4), r.Y + Pu(64) + dy, r.Width - Pu(8), Pu(20)), center);
                if (dy == 0)
                    using (var b = new SolidBrush(t.On ? Color.FromArgb(0xD0, 0xD0, 0xD0) : grey))
                        g.DrawString(t.Sub, fSub, b, new RectangleF(r.X + Pu(4), r.Y + Pu(84), r.Width - Pu(8), Pu(18)), center);
                int num = KeyNumber(i);
                if (num > 0)
                    using (var b = new SolidBrush(Color.FromArgb(0x5A, 0x5A, 0x5A)))
                        g.DrawString(num.ToString(), fIndex, b, r.X + Pu(7), r.Y + Pu(5));
            }
        }
    }

    // HDR Windows (API DisplayConfig, comme Paramètres > Affichage)
    public static class HdrControl {
        [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Lo; public int Hi; }
        [StructLayout(LayoutKind.Sequential)] struct PathInfo {
            public LUID srcAdapter; public uint srcId, srcMode, srcStatus;
            public LUID tgtAdapter; public uint tgtId, tgtMode, tech, rot, scale, rrNum, rrDen, scan; public int avail; public uint tgtStatus, flags;
        }
        [StructLayout(LayoutKind.Sequential)] struct Header { public int type, size; public LUID adapter; public uint id; }
        [StructLayout(LayoutKind.Sequential)] struct ColorInfo { public Header h; public uint value; public int encoding, bpc; }
        [StructLayout(LayoutKind.Sequential)] struct ColorInfo2 { public Header h; public uint value; public int encoding, bpc, mode; }
        [StructLayout(LayoutKind.Sequential)] struct SetState { public Header h; public uint value; }
        [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint f, out uint np, out uint nm);
        [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint f, ref uint np, [Out] PathInfo[] p, ref uint nm, IntPtr m, IntPtr t);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref ColorInfo i);
        [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref ColorInfo2 i);
        [DllImport("user32.dll")] static extern int DisplayConfigSetDeviceInfo(ref SetState i);

        static Header Hd(int type, int size, PathInfo p) { return new Header { type = type, size = size, adapter = p.tgtAdapter, id = p.tgtId }; }

        static PathInfo[] Paths() {
            uint np, nm;
            if (GetDisplayConfigBufferSizes(2 /* ACTIVE */, out np, out nm) != 0) return new PathInfo[0];
            var p = new PathInfo[np];
            var modes = Marshal.AllocHGlobal((int)nm * 64);
            try {
                if (QueryDisplayConfig(2, ref np, p, ref nm, modes, IntPtr.Zero) != 0) return new PathInfo[0];
            } finally { Marshal.FreeHGlobal(modes); }
            Array.Resize(ref p, (int)np);
            return p;
        }

        // supported / enabled de l'écran ; v2 = API Windows 11 24H2+
        static bool Query(PathInfo p, out bool enabled, out bool v2) {
            var c2 = new ColorInfo2();
            c2.h = Hd(15 /* GET_ADVANCED_COLOR_INFO_2 */, Marshal.SizeOf(c2), p);
            if (DisplayConfigGetDeviceInfo(ref c2) == 0) {
                v2 = true;
                enabled = (c2.value & 0x20) != 0;      // highDynamicRangeUserEnabled
                return (c2.value & 0x10) != 0;         // highDynamicRangeSupported
            }
            var c = new ColorInfo();
            c.h = Hd(9 /* GET_ADVANCED_COLOR_INFO */, Marshal.SizeOf(c), p);
            v2 = false;
            enabled = false;
            if (DisplayConfigGetDeviceInfo(ref c) != 0) return false;
            enabled = (c.value & 2) != 0;
            return (c.value & 1) != 0 && (c.value & 4) == 0;   // pas un écran SDR en couleurs étendues
        }

        // -1 = aucun écran HDR, 0 = désactivé, 1 = activé (sur au moins un écran)
        public static int Get() {
            int r = -1;
            foreach (var p in Paths()) {
                bool en, v2;
                if (Query(p, out en, out v2)) { if (en) return 1; r = 0; }
            }
            return r;
        }

        // Nombre d'écrans basculés
        public static int Set(bool on) {
            int n = 0;
            foreach (var p in Paths()) {
                bool en, v2;
                if (!Query(p, out en, out v2) || en == on) continue;
                var s = new SetState { value = on ? 1u : 0u };
                s.h = Hd(v2 ? 16 /* SET_HDR_STATE */ : 10 /* SET_ADVANCED_COLOR_STATE */, Marshal.SizeOf(s), p);
                if (DisplayConfigSetDeviceInfo(ref s) == 0) n++;
            }
            return n;
        }
    }

    // Mesures en lecture seule : mémoire partagée de MSI Afterburner (températures)
    // et NVML (limite de puissance du GPU = profil stock ou OC)
    public static class Sensors {
        [DllImport("nvml.dll")] static extern int nvmlInit_v2();
        [DllImport("nvml.dll")] static extern int nvmlDeviceGetHandleByIndex_v2(uint i, out IntPtr dev);
        [DllImport("nvml.dll")] static extern int nvmlDeviceGetEnforcedPowerLimit(IntPtr dev, out uint mw);
        [DllImport("nvml.dll")] static extern int nvmlDeviceGetPowerManagementDefaultLimit(IntPtr dev, out uint mw);
        [DllImport("nvml.dll")] static extern int nvmlDeviceGetTemperature(IntPtr dev, int sensor, out uint t);
        [DllImport("nvml.dll")] static extern int nvmlDeviceGetNumFans(IntPtr dev, out uint n);
        [DllImport("nvml.dll")] static extern int nvmlDeviceGetFanSpeed_v2(IntPtr dev, uint fan, out uint pct);

        public static float Cpu = float.NaN, Gpu = float.NaN;
        static IntPtr gpu = IntPtr.Zero;
        static bool nvmlTried;

        static bool Nvml() {
            if (gpu != IntPtr.Zero) return true;
            if (nvmlTried) return false;
            nvmlTried = true;
            try {
                if (nvmlInit_v2() == 0 && nvmlDeviceGetHandleByIndex_v2(0, out gpu) == 0) return true;
            } catch { }
            gpu = IntPtr.Zero;
            return false;
        }

        // Rafraîchit Cpu/Gpu ; false si Afterburner ne publie rien
        public static bool Read() {
            Cpu = Gpu = float.NaN;
            bool ok = false;
            try {
                using (var mm = MemoryMappedFile.OpenExisting("MAHMSharedMemory", MemoryMappedFileRights.Read))
                using (var v = mm.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read)) {
                    if (v.ReadUInt32(0) == 0x4D41484D /* 'MAHM' */) {
                        uint hs = v.ReadUInt32(8), n = v.ReadUInt32(12), es = v.ReadUInt32(16);
                        var name = new byte[260];
                        for (uint i = 0; i < n; i++) {
                            long o = hs + (long)i * es;
                            v.ReadArray(o, name, 0, 260);
                            string s = System.Text.Encoding.ASCII.GetString(name);
                            s = s.Substring(0, Math.Max(0, s.IndexOf('\0')));
                            float val = v.ReadSingle(o + 1300);
                            if (val > 1e30f) val = float.NaN;   // FLT_MAX = pas de mesure
                            if (s == "CPU temperature") Cpu = val;
                            else if (s == "GPU temperature" && float.IsNaN(Gpu)) Gpu = val;
                        }
                        ok = true;
                    }
                }
            } catch { }
            if (float.IsNaN(Gpu) && Nvml()) {
                uint t;
                if (nvmlDeviceGetTemperature(gpu, 0, out t) == 0) Gpu = t;
            }
            return ok;
        }

        // Vitesse (%) du ventilateur le plus rapide du GPU, lue au pilote (NVML) et
        // non via Afterburner : si Afterburner plante, les ventilateurs repassent
        // en automatique, et c'est justement ce qu'on veut voir. -1 = inconnu
        public static int GpuFanMax() {
            if (!Nvml()) return -1;
            uint n;
            if (nvmlDeviceGetNumFans(gpu, out n) != 0 || n == 0) return -1;
            int max = -1;
            for (uint i = 0; i < n; i++) {
                uint p;
                if (nvmlDeviceGetFanSpeed_v2(gpu, i, out p) == 0) max = Math.Max(max, (int)p);
            }
            return max;
        }

        // 1 = limite de puissance relevée (profil OC), 0 = défaut (stock), -1 = inconnu
        public static int GpuOverclocked() {
            if (!Nvml()) return -1;
            uint cur, def;
            if (nvmlDeviceGetEnforcedPowerLimit(gpu, out cur) != 0 || nvmlDeviceGetPowerManagementDefaultLimit(gpu, out def) != 0) return -1;
            return cur > def + 1000 ? 1 : 0;
        }
    }

    // Raccourci clavier simulé (SendInput) : utilisé seulement pour Alt+F10
    public static class KeySender {
        [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
        [StructLayout(LayoutKind.Sequential)] struct KEYBDINPUT { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
        [StructLayout(LayoutKind.Explicit)] struct UNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)] struct INPUT { public int type; public UNION u; }
        [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] i, int sz);
        [DllImport("user32.dll")] static extern uint MapVirtualKey(uint code, uint type);

        static INPUT Key(int vk, bool up) {
            var i = new INPUT { type = 1 };
            i.u.ki.vk = (ushort)vk;
            i.u.ki.scan = (ushort)MapVirtualKey((uint)vk, 0);
            i.u.ki.flags = up ? 2u : 0u;
            return i;
        }

        // Appuie les touches dans l'ordre puis les relâche à l'envers
        public static bool Chord(int[] vks) {
            var list = new List<INPUT>();
            foreach (var k in vks) list.Add(Key(k, false));
            for (int i = vks.Length - 1; i >= 0; i--) list.Add(Key(vks[i], true));
            return SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf(typeof(INPUT))) == list.Count;
        }
    }
}
'@

# ============================================================
#  TUILES
# ============================================================
function New-Tile([string]$id, [string]$glyph, [string]$accent) {
    $t = New-Object HotkeyDeck.Tile
    $t.Id = $id
    $t.Glyph = if ($glyph) { [string][char][Convert]::ToInt32($glyph, 16) } else { '' }
    $t.Accent = [System.Drawing.ColorTranslator]::FromHtml("#$accent")
    $t
}

# Une colonne par thème, puis une barre d'état (lecture seule) en bas :
#
#     SON          ÉCRAN          JEU
#   [Casque]     [HDR]          [Overclock GPU]
#   [Enceintes]  [Écran noir]   [Instant Replay]
#   ──────────────────────────────────────────
#    Micro actif    CPU 46°    GPU 27°
#
# Les cartes « allumées » (teintées) sont les états actifs. L'ordre des tuiles
# donne les touches 1-6 (colonne par colonne).
function Add-Tile([string]$id, [string]$glyph, [string]$accent, [int]$col, [int]$row, [string]$title = '') {
    $t = New-Tile $id $glyph $accent
    $t.Col = $col; $t.Row = $row; $t.Title = $title
    if ($row -lt 0) { $t.Clickable = $false }
    $DeckTiles[$id] = $t
    $deck.Tiles.Add($t)
}

$deck = New-Object HotkeyDeck.DeckForm
$deck.Headers = [string[]]@('SON', 'ÉCRAN', 'JEU')
$DeckTiles = [ordered]@{}
Add-Tile 'casque'    'E7F6' '4CC2FF' 0 0 'Casque'
Add-Tile 'enceintes' 'E7F5' '4CC2FF' 0 1 'Enceintes'
Add-Tile 'hdr'       'E706' 'FFC83D' 1 0 'HDR'
Add-Tile 'black'     'E708' 'B4A7FF' 1 1 'Écran noir'
Add-Tile 'gpu'       'EC4A' 'FF8C42' 2 0 'Overclock GPU'
Add-Tile 'replay'    'E7C8' '76B900' 2 1 'Instant Replay'
# Barre d'état. Le micro est vérifié à chaque appui sur son capteur et à
# l'ouverture du deck : il n'a pas besoin d'être cliquable
Add-Tile 'mic'       'E720' '3FB950' 0 -1 'Micro'
Add-Tile 'cpu'       ''     'FFFFFF' 1 -1 'CPU'
Add-Tile 'gputemp'   ''     'FFFFFF' 2 -1 'GPU'
$DeckTiles.black.Sub = 'Échap pour quitter'

# Un bouton par profil : celui qui est actif est allumé, avec son volume
function Update-DeckAudio {
    foreach ($key in 'casque', 'enceintes') {
        $t = $DeckTiles[$key]
        $t.On = $S.Active -eq $key
        $t.Sub = if ($t.On) { "$(Fmt $S.Profiles[$key].Cur) dB" } else { '' }
    }
}

function Update-DeckMic {
    $t = $DeckTiles.mic
    $m = $S.Mic
    if (-not $m.Connected) {
        $t.Glyph = [string][char]0xF781; $t.Value = 'débranché'
        $t.Accent = [System.Drawing.ColorTranslator]::FromHtml('#8B949E')
    } elseif ($m.State -eq [HotkeyDeck.MicWatcher]::Muted) {
        $t.Glyph = [string][char]0xF781; $t.Value = 'coupé'
        $t.Accent = [System.Drawing.ColorTranslator]::FromHtml('#F85149')
    } elseif ($m.State -eq [HotkeyDeck.MicWatcher]::Active) {
        $t.Glyph = [string][char]0xE720; $t.Value = 'actif'
        $t.Accent = [System.Drawing.ColorTranslator]::FromHtml('#3FB950')
    } else {
        $t.Glyph = [string][char]0xE720; $t.Value = '?'
        $t.Accent = [System.Drawing.ColorTranslator]::FromHtml('#8B949E')
    }
}

function Update-DeckHdr {
    $t = $DeckTiles.hdr
    $h = [HotkeyDeck.HdrControl]::Get()
    $t.On = $h -eq 1
    $t.Clickable = $h -ge 0
    $t.Sub = if ($h -lt 0) { 'Non supporté' } else { '' }
}

function Update-DeckGpu {
    $t = $DeckTiles.gpu
    $oc = [HotkeyDeck.Sensors]::GpuOverclocked()
    $t.On = $oc -eq 1
    $t.Sub = if ($oc -lt 0) { 'NVML indisponible' } else { '' }
}

function Format-Temp([float]$v) { if ([float]::IsNaN($v)) { '–' } else { '{0:0}°' -f $v } }

function Update-DeckTemps {
    [void][HotkeyDeck.Sensors]::Read()   # « – » si Afterburner est fermé
    $DeckTiles.cpu.Value     = Format-Temp ([HotkeyDeck.Sensors]::Cpu)
    $DeckTiles.gputemp.Value = Format-Temp ([HotkeyDeck.Sensors]::Gpu)
}

# ============================================================
#  ACTIONS
# ============================================================
function Toggle-Hdr {
    $on = [HotkeyDeck.HdrControl]::Get() -ne 1
    $n = [HotkeyDeck.HdrControl]::Set($on)
    Log "Deck : HDR $(if ($on) { 'activé' } else { 'désactivé' }) sur $n écran(s)"
    if ($n -gt 0) { Show-Osd 'HDR' $(if ($on) { 'Activé' } else { 'Désactivé' }) 1500 }
    else          { Show-Osd '⚠ HDR' 'Échec' 2500 '801010' }
}

function Toggle-GpuProfile {
    if (-not (Test-Path $DeckCfg.Afterburner)) {
        Log "Deck : Afterburner introuvable ($($DeckCfg.Afterburner))"
        Show-Osd '⚠ GPU' 'Afterburner absent' 2500 '801010'
        return
    }
    # Pendant la confirmation d'un changement en cours, la limite de puissance
    # n'a peut-être pas encore suivi : on part de l'état demandé
    $toOc = if ($deckGpuCheck.Enabled) { -not $S.DeckGpuExpect } else { [HotkeyDeck.Sensors]::GpuOverclocked() -ne 1 }
    $n = if ($toOc) { $DeckCfg.ProfileOC } else { $DeckCfg.ProfileStock }
    # Une 2e instance d'Afterburner transmet le profil à celle qui tourne, puis se ferme
    Start-Process $DeckCfg.Afterburner -ArgumentList "-Profile$n"
    Log "Deck : profil Afterburner $n demandé ($(if ($toOc) { 'OC' } else { 'stock' }))"
    $S.DeckGpuExpect = [int]$toOc
    $DeckTiles.gpu.On = $toOc   # affichage immédiat, confirmé par la vérification
    $deckGpuCheck.Stop(); $deckGpuCheck.Start()
}

# Vérifie quelques secondes plus tard que la limite de puissance a suivi
$deckGpuCheck = New-Object System.Windows.Forms.Timer
$deckGpuCheck.Interval = 3000
$deckGpuCheck.add_Tick({ Safe {
    $deckGpuCheck.Stop()
    $oc = [HotkeyDeck.Sensors]::GpuOverclocked()
    if ($oc -ge 0 -and $oc -ne $S.DeckGpuExpect) {
        Log "Deck : le profil Afterburner ne s'est pas appliqué (limite de puissance inchangée)"
        Show-Osd '⚠ GPU' 'Profil non appliqué' 3000 '801010'
    }
    # Carte du deck : état réel
    Update-DeckGpu
    if ($deck.Visible) { $deck.Invalidate() }
}})

# Instant Replay NVIDIA : Alt+F10 envoyé pendant que le deck a le focus (le jeu
# ne reçoit pas la touche), puis on rend la main au jeu une fois la touche traitée
$deckReplayDone = New-Object System.Windows.Forms.Timer
$deckReplayDone.Interval = 200
$deckReplayDone.add_Tick({ Safe {
    $deckReplayDone.Stop()
    $deck.HideDeck($true)
    Show-Osd '' 'Sauvegarde' 1500 '202020' ([string][char]0xE7C8)
}})

function Save-Replay {
    if (-not [HotkeyDeck.KeySender]::Chord([int[]]$DeckCfg.ReplayKeys)) { Log 'Deck : SendInput Alt+F10 refusé' }
    else { Log 'Deck : Alt+F10 envoyé (Instant Replay)' }
    $deckReplayDone.Start()
}

function Invoke-DeckAction([string]$id) {
    switch ($id) {
        # Son et GPU : le deck reste ouvert et sa carte change, sans OSD en
        # doublon (les OSD d'erreur restent)
        { $_ -in 'casque', 'enceintes' } {
            # Pas de bascule : le profil déjà actif n'est pas réappliqué (ça
            # remettrait le volume par défaut)
            if ($S.Active -ne $id) { Switch-Profile $id -Quiet }
            Update-DeckAudio; $deck.Invalidate()
        }
        'gpu'    { Toggle-GpuProfile; $deck.Invalidate() }
        'hdr'    { $deck.HideDeck($true); Toggle-Hdr }
        'replay' { Save-Replay }
        'black'  { $deck.HideDeck($false); Show-BlackScreen }
    }
}

# ============================================================
#  ALERTE TEMPÉRATURE
# ============================================================
# Hausse soutenue (pas un pic d'une seconde) : une alerte par dépassement,
# réarmée une fois redescendu sous le seuil de réarmement
$S.TempWatch = @{
    CPU = @{ Above = 0; Alerted = $false }
    GPU = @{ Above = 0; Alerted = $false }
}

function Check-Temps {
    [void][HotkeyDeck.Sensors]::Read()
    $vals = @{ CPU = [HotkeyDeck.Sensors]::Cpu; GPU = [HotkeyDeck.Sensors]::Gpu }
    $new = $false
    foreach ($k in 'CPU', 'GPU') {
        $v = $vals[$k]; $w = $S.TempWatch[$k]
        if ([float]::IsNaN($v)) { continue }
        if ($v -ge $DeckCfg.TempAlert) {
            $w.Above++
            if ($w.Above -ge $DeckCfg.TempSustain -and -not $w.Alerted) { $w.Alerted = $true; $new = $true }
        } else {
            $w.Above = 0
            if ($w.Alerted -and $v -lt $DeckCfg.TempReset) {
                $w.Alerted = $false
                Log ("Température : {0} revenu à {1:0}°" -f $k, $v)
            }
        }
    }
    if ($new) {
        # Affiche toutes les mesures au-dessus du seuil, pas seulement la nouvelle
        $hot = foreach ($k in 'CPU', 'GPU') { if ($vals[$k] -ge $DeckCfg.TempAlert) { "$k $(Format-Temp $vals[$k])" } }
        $txt = $hot -join '  '   # « CPU 68°  GPU 70° » tient tout juste dans l'OSD
        Log "Température : alerte $txt (seuil $($DeckCfg.TempAlert)°)"
        Show-Osd "⚠ Température > $($DeckCfg.TempAlert)°" $txt 4000 '804000'
    }
}

# ============================================================
#  ALERTE VENTILATEURS GPU (bandeau permanent)
# ============================================================
# Bandeau rouge en haut au centre de l'écran principal, distinct de l'OSD du
# bas (un changement de volume ne le masque pas), transparent aux clics.
# Reste affiché tant qu'un ventilateur dépasse FanMax.
$fanBanner = New-Object HotkeyDeck.OsdForm
$fanBanner.FormBorderStyle = 'None'
$fanBanner.StartPosition   = 'Manual'
$fanBanner.ShowInTaskbar   = $false
$fanBanner.TopMost         = $true
$fanBanner.BackColor       = [System.Drawing.ColorTranslator]::FromHtml('#8B1A1A')
$fanBanner.Opacity         = 0.95
$fanBanner.ClientSize      = New-Object System.Drawing.Size((Px 320), (Px 44))
$scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$fanBanner.Location = New-Object System.Drawing.Point(
    [int]($scr.X + [Math]::Floor(($scr.Width - $fanBanner.Width) / 2)), [int]($scr.Y + (Px 24)))
$fanText = New-Object System.Windows.Forms.Label
$fanText.AutoSize  = $false
$fanText.Dock      = 'Fill'
$fanText.TextAlign = 'MiddleCenter'
$fanText.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$fanText.ForeColor = [System.Drawing.Color]::White
$fanBanner.Controls.Add($fanText)
$fanBanner.add_HandleCreated({
    $v = 2
    [HotkeyDeck.Native]::DwmSetWindowAttribute($fanBanner.Handle, 33, [ref]$v, 4) | Out-Null
})
$S.FanWatch = @{ Above = 0; Shown = $false }

function Check-Fans {
    $pct = [HotkeyDeck.Sensors]::GpuFanMax()
    if ($pct -lt 0) { return }
    $w = $S.FanWatch
    if ($pct -gt $DeckCfg.FanMax) {
        $w.Above++
        if ($w.Above -lt $DeckCfg.TempSustain) { return }
        $fanText.Text = "⚠  Ventilateurs GPU à $pct %"
        if (-not $w.Shown) {
            $w.Shown = $true
            Log "Ventilateurs GPU : $pct % (> $($DeckCfg.FanMax) %), bandeau affiché"
            $fanBanner.Show()
        }
        $fanBanner.TopMost = $true
    } else {
        $w.Above = 0
        if ($w.Shown) {
            $w.Shown = $false
            Log "Ventilateurs GPU : revenus à $pct %, bandeau retiré"
            $fanBanner.Hide()
        }
    }
}

$tempTimer = New-Object System.Windows.Forms.Timer
$tempTimer.Interval = $DeckCfg.TempCheckMs
$tempTimer.add_Tick({ Safe { Check-Temps }; Safe { Check-Fans } })
$tempTimer.Start()

# ============================================================
#  OUVERTURE / RAFRAÎCHISSEMENT
# ============================================================
function Open-Deck {
    if ($S.Black.Count) { Log 'Deck : ignoré, écran noir affiché'; return }   # pas par-dessus l'écran noir
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # Une tuile qui échoue ne doit pas empêcher le deck de s'ouvrir
    foreach ($u in 'Update-DeckAudio', 'Update-DeckMic', 'Update-DeckHdr', 'Update-DeckGpu', 'Update-DeckTemps') {
        try { & $u } catch { Log "Deck : $u en erreur : $($_.Exception.Message)" }
    }
    $prep = $sw.ElapsedMilliseconds
    $S.DeckNoFocus = $false
    $res = $deck.ShowDeck()
    Log "Deck : ouvert $res (préparation $prep ms)"
    $deckTimer.Start()
    # Revérifie l'état réel du micro ; la tuile suit dès que le résultat arrive
    if ($S.Mic.Connected) { $micWatcher.Recheck() }
}

# Noms des combinaisons de variantes (bit 1 = Maj, 2 = Ctrl, 4 = Alt)
function Format-Mods([int]$m) {
    $n = @()
    if ($m -band 1) { $n += 'Maj' }
    if ($m -band 2) { $n += 'Ctrl' }
    if ($m -band 4) { $n += 'Alt' }
    if ($n) { ($n -join '+') + '+' } else { '' }
}

function Toggle-Deck([int]$mods = 0) {
    Log "Deck : touche $(Format-Mods $mods)² (fenêtre active : $([HotkeyDeck.DeckForm]::DescribeForeground()))"
    if ($deck.Visible) { $deck.HideDeck($true, 'touche ²') } else { Open-Deck }
}

# Températures et micro rafraîchis tant que le deck est ouvert
$deckTimer = New-Object System.Windows.Forms.Timer
$deckTimer.Interval = 1000
$deckTimer.add_Tick({ Safe {
    if (-not $deck.Visible) { $deckTimer.Stop(); return }
    if (-not $deck.HasFocus) {
        $deck.FocusLost()   # ferme si Alt/Windows encore enfoncé (changement de fenêtre voulu)
        if (-not $deck.Visible) { $deckTimer.Stop(); return }
        # Affiché sans le focus : le jeu garde la souris, ² ferme le deck (diagnostic)
        if (-not $S.DeckNoFocus) { Log "Deck : affiché sans le focus (actif : $([HotkeyDeck.DeckForm]::DescribeForeground()))" }
        $S.DeckNoFocus = $true
    } else { $S.DeckNoFocus = $false }
    Update-DeckMic; Update-DeckTemps
    $deck.Invalidate()
}})

$deck.add_TileClicked({ param($id) Safe { Invoke-DeckAction $id } })

$deck.add_Info({ param($m) Safe { Log "Deck : $m" } })

# Touche ² (VK_OEM_7 en AZERTY), sans répétition : Windows la consomme (elle ne
# tape plus de ²) et WM_HOTKEY autorise le deck à passer au premier plan.
# RegisterHotKey exige les modificateurs exacts : on réserve aussi les variantes
# Maj/Ctrl/Alt (ids 17..77), sinon ² ne répond pas en jeu pendant un sprint (Maj)
# ou accroupi (Ctrl).
$err = $S.Hk.Register(7, $MOD_NOREPEAT, 0xDE)
if ($err) { Log "Deck : touche ² non réservée (err $err), deck inaccessible" }
foreach ($m in 1..7) {
    $mod = $MOD_NOREPEAT
    if ($m -band 1) { $mod = $mod -bor $MOD_SHIFT }
    if ($m -band 2) { $mod = $mod -bor $MOD_CONTROL }
    if ($m -band 4) { $mod = $mod -bor $MOD_ALT }
    $err = $S.Hk.Register(7 + 10 * $m, $mod, 0xDE)
    if ($err) { Log "Deck : variante $(Format-Mods $m)² non réservée (err $err)" }
}
