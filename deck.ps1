# Deck — "Stream Deck" à l'écran, chargé par hotkey_deck.ps1 (dot-source)
#
# La touche ² (AZERTY, à gauche de 1) ouvre une grille de
# boutons au centre de l'écran du jeu / de la fenêtre active ; un clic lance
# une action (souris seulement). Échap, ² ou un clic ailleurs referme.
#
# Compatible anti-cheat, comme le reste du script :
#   - touche ² réservée via RegisterHotKey (Windows l'avale : elle ne tape
#     plus de ²), pas de hook clavier bas niveau
#   - températures lues dans la mémoire partagée d'Afterburner, état du GPU via
#     NVML (lecture seule) : aucun pilote ni accès matériel de notre côté
#   - second écran piloté par DDC/CI via l'API Windows (dxva2), comme le
#     logiciel des fabricants d'écrans
#   - aucune entrée clavier ou souris simulée
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
    SideScreen   = 'PHLC0D2'   # identifiant PnP du second écran (Philips 273V5), allumé / éteint par DDC/CI
    # Bandeau d'alerte si le CPU ou le GPU reste au-dessus de TempAlert (°C)
    # pendant TempSustain relevés de suite (un toutes les TempCheckMs) ; il
    # reste affiché jusqu'à être redescendu sous TempReset. En jeu : ~58 °C CPU,
    # ~60 °C GPU (max 63 °C), d'où une marge pour l'été sans fausse alerte
    TempAlert    = 72
    TempReset    = 68
    TempSustain  = 2
    TempCheckMs  = 5000
    # Bandeau aussi si une température n'est plus lue pendant SensorGrace
    # relevés de suite (CPU : Afterburner fermé ou monitoring désactivé)
    SensorGrace  = 12
    # Bandeau si un ventilateur du GPU dépasse FanMax (%) pendant TempSustain
    # relevés de suite (ventilateurs fixés à 35 % dans Afterburner)
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

        // Dimensions en pixels à 100 % : carte, écart entre les cartes d'une paire,
        // entre deux paires, marge, barre du bas (hauteur, écart entre le trait et
        // ce qui l'entoure), segment du sélecteur audio (largeur, retrait de la pastille
        // active)
        const int TW = 160, TH = 128, GAP = 12, PAIRGAP = 28, PAD = 18, BAR = 40, LINE = 18, SW = 140, SEGINSET = 3;

        public List<Tile> Tiles = new List<Tile>();
        public event Action<string> TileClicked;
        public event Action<string> Info;   // historique (journal) : fermetures, focus perdu
        public bool Exclusive;        // plein écran exclusif détecté au dernier affichage
        int shownAt;
        int regrabs;   // reprises du focus depuis l'ouverture
        string fgMethod = "";

        readonly List<Rectangle> rects = new List<Rectangle>();
        readonly Dictionary<Font, int> baseFix = new Dictionary<Font, int>();   // voir BaseFix
        Rectangle barRect;
        int lineY;   // trait de séparation, à mi-chemin entre les cartes et la barre
        Rectangle segRect;   // bloc du sélecteur audio (boutons de la barre, accolés)
        readonly Timer fade = new Timer { Interval = 15 };
        IntPtr prevFg;
        float scale = 1f;
        int hover = -1, pressed = -1;
        Font fGlyph, fTitle, fSub, fBarLabel, fBarValue, fBarGlyph;

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
            foreach (var f in new[] { fGlyph, fTitle, fSub, fBarLabel, fBarValue, fBarGlyph }) if (f != null) f.Dispose();
            fGlyph     = new Font("Segoe Fluent Icons", Pu(30), GraphicsUnit.Pixel);
            fTitle     = new Font("Segoe UI Semibold", Pu(14), GraphicsUnit.Pixel);
            fSub       = new Font("Segoe UI", Pu(11.5), GraphicsUnit.Pixel);
            fBarLabel  = new Font("Segoe UI", Pu(12.5), GraphicsUnit.Pixel);
            fBarValue  = new Font("Segoe UI Semibold", Pu(16), GraphicsUnit.Pixel);
            fBarGlyph  = new Font("Segoe Fluent Icons", Pu(17), GraphicsUnit.Pixel);
            baseFix.Clear();
            foreach (var f in new[] { fTitle, fBarLabel, fBarValue }) baseFix[f] = BaseFix(f);
        }

        // Abscisse (à 100 %) de la colonne c : les cartes vont par paires
        static int ColX(int c) { return PAD + c * (TW + GAP) + (c / 2) * (PAIRGAP - GAP); }

        // Cartes placées par (Col, Row) ; tuiles Row = -1 : barre du bas (LayoutBar)
        Size LayoutTiles() {
            rects.Clear();
            int cols = 1, rows = 1;
            bool bar = false;
            foreach (var t in Tiles) {
                if (t.Row < 0) { bar = true; continue; }
                cols = Math.Max(cols, t.Col + 1);
                rows = Math.Max(rows, t.Row + 1);
            }
            int w = ColX(cols - 1) + TW + PAD;
            int gridBottom = PAD + rows * TH + (rows - 1) * GAP;
            // Trait de séparation à égale distance des cartes et de la barre
            int barTop = gridBottom + 2 * LINE;
            barRect = new Rectangle(Px(PAD), Px(barTop), Px(w) - 2 * Px(PAD), Px(BAR));
            lineY = (Px(gridBottom) + barRect.Y) / 2;
            // Colonnes de droite placées en miroir de celles de gauche : l'arrondi à
            // 125 % décalerait sinon l'espace central d'1 ou 2 px
            foreach (var t in Tiles)
                rects.Add(t.Row >= 0 ? new Rectangle(2 * t.Col < cols ? Px(ColX(t.Col)) : Px(w) - Px(ColX(cols - 1 - t.Col)) - Px(TW),
                    Px(PAD + t.Row * (TH + GAP)), Px(TW), Px(TH)) : Rectangle.Empty);
            if (bar)
                using (var bmp = new Bitmap(1, 1))
                using (var g = Graphics.FromImage(bmp)) {
                    g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;   // comme au dessin
                    LayoutBar(g);
                }
            return new Size(Px(w), bar ? Px(barTop + BAR + PAD) : Px(gridBottom + PAD));
        }

        // Barre du bas : sélecteur (tuiles cliquables, accolées en segments) centré
        // sous la paire de cartes de gauche, état (non cliquable) sous celle de
        // droite. Refait à chaque dessin : la largeur de l'état dépend de la valeur
        // affichée
        void LayoutBar(Graphics g) {
            int nseg = 0;
            Tile status = null;
            foreach (var t in Tiles) if (t.Row < 0) { if (t.Clickable) nseg++; else status = t; }
            int segW = Px(nseg * SW);
            int sw = status == null ? 0 : (int)Math.Ceiling(StatusWidth(g, status, status.Value));
            // Sommes bord gauche + bord droit (= 2 × milieu) de chaque paire, celle de
            // droite en miroir comme les cartes
            int sumL = Px(ColX(0)) + Px(ColX(1)) + Px(TW);
            int sumR = 2 * (barRect.X + barRect.Right) - sumL;
            int x0 = status == null ? barRect.X + (barRect.Width - segW) / 2 : (sumL - segW) / 2;
            segRect = new Rectangle(x0, barRect.Y, segW, barRect.Height);
            int k = 0;
            for (int i = 0; i < Tiles.Count; i++) {
                var t = Tiles[i];
                if (t.Row >= 0) continue;
                if (t.Clickable) {
                    rects[i] = new Rectangle(x0 + Px(k * SW), barRect.Y, Px((k + 1) * SW) - Px(k * SW), barRect.Height);
                    k++;
                } else
                    rects[i] = new Rectangle((sumR - sw) / 2, barRect.Y, sw, barRect.Height);
            }
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

        // Souris seulement : aucune touche ne lance d'action (un 1 tapé par
        // réflexe en jeu, pour changer d'arme, déclencherait un bouton)
        protected override void OnKeyDown(KeyEventArgs e) {
            if (e.KeyCode == Keys.Escape) HideDeck(true, "Échap");
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

        // Marge vide à gauche d'une icône dans sa boîte : on aligne ce qui est
        // réellement dessiné, sinon le groupe paraît décalé vers la droite
        static float GlyphLead(string glyph, Font f, StringFormat fmt) {
            if (string.IsNullOrEmpty(glyph)) return 0;
            using (var p = new GraphicsPath()) {
                p.AddString(glyph, f.FontFamily, (int)f.Style, f.Size, PointF.Empty, fmt);
                return Math.Max(0, p.GetBounds().X);
            }
        }

        // Distance entre le haut du texte (tel que DrawString le place) et sa
        // ligne de base : pour aligner des textes de tailles différentes
        static float Ascent(Font f) {
            var ff = f.FontFamily;
            return f.Size * ff.GetCellAscent(f.Style) / ff.GetEmHeight(f.Style);
        }

        // Ligne de base d'un texte centré verticalement sur cy, arrondie au pixel :
        // le lissage place alors au même niveau des textes de tailles différentes
        float Baseline(Graphics g, Font f, float cy) { return (float)Math.Round(cy - f.GetHeight(g) / 2 + Ascent(f)); }

        // Le lissage arrondit la ligne de base de chaque police à sa façon (un
        // texte de 18 px finit un pixel plus haut qu'un de 20 px placé sur la même
        // ligne) : on mesure une fois de combien de pixels corriger chaque police
        static int BaseFix(Font f) {
            const int B = 40;   // ligne de base visée : le bas des jambages doit tomber sur B - 1
            using (var bmp = new Bitmap(f.Height * 3 + 20, B + 20))
            using (var g = Graphics.FromImage(bmp)) {
                g.Clear(Color.Black);
                g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
                g.DrawString("nnn", f, Brushes.White, 0, B - Ascent(f), StringFormat.GenericTypographic);
                int last = -1;
                for (int y = 0; y < bmp.Height; y++)
                    for (int x = 0; x < bmp.Width; x++)
                        if (bmp.GetPixel(x, y).G > 127) { last = y; break; }
                return last < 0 ? 0 : B - 1 - last;
            }
        }

        // Ordonnée où dessiner un texte pour que sa ligne de base tombe sur baseY
        float TextTop(Font f, float baseY) {
            int fix;
            return baseY - Ascent(f) + (baseFix.TryGetValue(f, out fix) ? fix : 0);
        }

        // Largeurs de l'état : icône + écart, titre + écart, valeur
        void StatusParts(Graphics g, Tile t, string value, out float gw, out float lw, out float vw) {
            var fmt = StringFormat.GenericTypographic;
            gw = string.IsNullOrEmpty(t.Glyph) ? 0 : g.MeasureString(t.Glyph, fBarGlyph, 1000, fmt).Width + Pu(6);
            lw = g.MeasureString(t.Title, fBarLabel, 1000, fmt).Width + Pu(6);
            vw = string.IsNullOrEmpty(value) ? 0 : g.MeasureString(value, fBarValue, 1000, fmt).Width;
        }

        // Largeur réellement dessinée de l'état (sans la marge vide de l'icône)
        float StatusWidth(Graphics g, Tile t, string value) {
            float gw, lw, vw;
            StatusParts(g, t, value, out gw, out lw, out vw);
            return gw + lw + vw - GlyphLead(t.Glyph, fBarGlyph, StringFormat.GenericTypographic);
        }

        // État de la barre, aligné à gauche dans sa place : [icône] Titre Valeur
        // (en couleur d'accent), sur la ligne de base de la barre
        void DrawStatus(Graphics g, Tile t, Rectangle r, Color grey) {
            var fmt = StringFormat.GenericTypographic;
            float gw, lw, vw;
            StatusParts(g, t, t.Value, out gw, out lw, out vw);
            float x = r.X - GlyphLead(t.Glyph, fBarGlyph, fmt), cy = r.Y + r.Height / 2f;
            float baseY = Baseline(g, fTitle, cy);   // même ligne que les titres du sélecteur
            if (gw > 0)
                using (var b = new SolidBrush(t.Accent))
                    g.DrawString(t.Glyph, fBarGlyph, b, x, cy - fBarGlyph.GetHeight(g) / 2, fmt);
            using (var b = new SolidBrush(grey))
                g.DrawString(t.Title, fBarLabel, b, x + gw, TextTop(fBarLabel, baseY), fmt);
            using (var b = new SolidBrush(t.Accent))
                g.DrawString(t.Value, fBarValue, b, x + gw + lw, TextTop(fBarValue, baseY), fmt);
        }

        // Fond d'une carte : teinté de la couleur d'accent si elle est active, éclairci au survol
        void DrawCard(Graphics g, Tile t, Rectangle r, int i, int radius, Color baseBg) {
            Color bg = t.On ? Mix(baseBg, t.Accent, 0.28) : baseBg;
            if (t.Clickable && i == hover) bg = Mix(bg, Color.White, i == pressed ? 0.03 : 0.08);
            using (var path = Round(r, radius))
            using (var br = new SolidBrush(bg)) {
                g.FillPath(br, path);
                if (t.On) using (var pen = new Pen(Mix(bg, t.Accent, 0.6), Pu(1.5))) g.DrawPath(pen, path);
            }
        }

        // Segment du sélecteur audio : pastille teintée (en retrait dans le bloc)
        // s'il est actif, éclaircie au survol ; contenu centré : [icône] Titre
        void DrawSegment(Graphics g, Tile t, Rectangle r, int i, Color baseBg) {
            if (t.On || i == hover)
                DrawCard(g, t, Rectangle.Inflate(r, -Px(SEGINSET), -Px(SEGINSET)), i, Pu(10) - Px(SEGINSET), baseBg);
            var fmt = StringFormat.GenericTypographic;
            float gw = g.MeasureString(t.Glyph, fBarGlyph, 1000, fmt).Width + Pu(7);
            float lw = g.MeasureString(t.Title, fTitle, 1000, fmt).Width;
            float lead = GlyphLead(t.Glyph, fBarGlyph, fmt);
            float x = r.X + (r.Width - gw - lw - lead) / 2, cy = r.Y + r.Height / 2f;
            using (var b = new SolidBrush(t.Accent))
                g.DrawString(t.Glyph, fBarGlyph, b, x, cy - fBarGlyph.GetHeight(g) / 2, fmt);
            using (var b = new SolidBrush(Color.White))
                g.DrawString(t.Title, fTitle, b, x + gw, TextTop(fTitle, Baseline(g, fTitle, cy)), fmt);
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

            // Barre du bas : séparée des cartes par un trait
            if (barRect.Height > 0) {
                LayoutBar(g);
                using (var pen = new Pen(Color.FromArgb(0x38, 0x38, 0x38), Math.Max(1, Px(1))))
                    g.DrawLine(pen, barRect.X, lineY, barRect.Right, lineY);
            }

            // Bloc du sélecteur audio, sous ses segments
            if (segRect.Width > 0)
                using (var path = Round(segRect, Pu(10)))
                using (var br = new SolidBrush(baseBg)) g.FillPath(br, path);

            for (int i = 0; i < Tiles.Count && i < rects.Count; i++) {
                var t = Tiles[i];
                var r = rects[i];

                if (t.Row < 0) {
                    if (t.Clickable) DrawSegment(g, t, r, i, baseBg);
                    else DrawStatus(g, t, r, grey);
                    continue;
                }

                DrawCard(g, t, r, i, Pu(10), baseBg);

                // Sans sous-titre, icône et titre sont recentrés verticalement
                int dy = string.IsNullOrEmpty(t.Sub) ? Pu(9) : 0;
                using (var b = new SolidBrush(t.Accent))
                    g.DrawString(t.Glyph, fGlyph, b, new RectangleF(r.X, r.Y + Pu(14) + dy, r.Width, Pu(44)), center);
                using (var b = new SolidBrush(Color.White))
                    g.DrawString(t.Title, fTitle, b, new RectangleF(r.X + Pu(4), r.Y + Pu(64) + dy, r.Width - Pu(8), Pu(20)), center);
                if (dy == 0)
                    using (var b = new SolidBrush(t.On ? Color.FromArgb(0xD0, 0xD0, 0xD0) : grey))
                        g.DrawString(t.Sub, fSub, b, new RectangleF(r.X + Pu(4), r.Y + Pu(84), r.Width - Pu(8), Pu(18)), center);
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

    // Alimentation d'un écran par DDC/CI (code VCP 0xD6, comme le bouton
    // marche/arrêt), via dxva2 : l'écran écoute encore une fois éteint au
    // bouton tant qu'il reste branché. Écran repéré par son identifiant PnP
    // (ex. PHLC0D2), Windows le nommant « Generic PnP Monitor ». Chaque échange
    // DDC prend ~70 ms : lecture et écriture se font hors du thread de l'UI,
    // State garde la dernière valeur lue
    public static class MonitorPower {
        public const int On = 1, Off = 5;   // 5 = éteint comme au bouton (l'écran reste à l'écoute)
        public static volatile int State = -1;   // 1 = allumé, 2..5 = veille / éteint, -1 = inconnu (écran absent ou muet)

        delegate bool MonEnum(IntPtr h, IntPtr dc, IntPtr r, IntPtr d);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct MONITORINFOEX { public int cb; public int l, t, r, b, wl, wt, wr, wb; public uint flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dev; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct DISPLAY_DEVICE { public int cb;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string name;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string str;
            public uint flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string id;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string key; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        struct PHYS { public IntPtr h; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }
        [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonEnum cb, IntPtr d);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr h, ref MONITORINFOEX i);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE d, uint f);
        [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr h, out uint n);
        [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr h, uint n, [Out] PHYS[] a);
        [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitors(uint n, PHYS[] a);
        [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr t, out uint cur, out uint max);
        [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint v);

        static readonly object busy = new object();   // un seul échange DDC à la fois

        // Écran Windows (HMONITOR) dont l'identifiant contient \pnp\
        static IntPtr Find(string pnp) {
            var found = IntPtr.Zero;
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (h, dc, r, d) => {
                var mi = new MONITORINFOEX(); mi.cb = Marshal.SizeOf(mi);
                if (!GetMonitorInfo(h, ref mi)) return true;
                var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
                for (uint i = 0; EnumDisplayDevices(mi.dev, i, ref dd, 0); i++)
                    if (dd.id.IndexOf("\\" + pnp + "\\", StringComparison.OrdinalIgnoreCase) >= 0) { found = h; return false; }
                return true;
            }, IntPtr.Zero);
            return found;
        }

        static bool With(string pnp, Func<IntPtr, bool> f) {
            lock (busy) {
                var h = Find(pnp);
                uint n;
                if (h == IntPtr.Zero || !GetNumberOfPhysicalMonitorsFromHMONITOR(h, out n) || n == 0) return false;
                var a = new PHYS[n];
                if (!GetPhysicalMonitorsFromHMONITOR(h, n, a)) return false;
                try { return f(a[0].h); } finally { DestroyPhysicalMonitors(n, a); }
            }
        }

        static int Read(string pnp) {
            int s = -1;
            With(pnp, p => { uint c, m; if (GetVCPFeatureAndVCPFeatureReply(p, 0xD6, IntPtr.Zero, out c, out m)) s = (int)c; return true; });
            return s;
        }

        static int gen;   // incrémenté à chaque Set : une lecture lancée avant est périmée

        // Relit State en arrière-plan
        public static void Refresh(string pnp) {
            int g = gen;
            System.Threading.ThreadPool.QueueUserWorkItem(_ => {
                int s = Read(pnp);
                if (g == gen) State = s;
            });
        }

        // Envoie l'état en arrière-plan ; State le reflète tout de suite (l'écran
        // ne répond plus pendant qu'il s'allume : relire quelques secondes après)
        public static void Set(string pnp, int v) {
            System.Threading.Interlocked.Increment(ref gen);
            State = v;
            System.Threading.ThreadPool.QueueUserWorkItem(_ => {
                if (!With(pnp, p => SetVCPFeature(p, 0xD6, (uint)v))) State = -1;
            });
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

# Les quatre actions sur une ligne, par paires, puis la barre audio en bas :
#
#   [HDR] [Overclock GPU]   [Écran noir] [Écran Philips]
#   ─────────────────────────────────────────────────────
#             ( Casque | Enceintes )    Micro actif
#
# HDR et OC se règlent avant de lancer un jeu, selon sa compatibilité ; les
# deux boutons d'écran servent n'importe quand. Un bouton « allumé »
# (teinté) est un état actif.
function Add-Tile([string]$id, [string]$glyph, [string]$accent, [int]$col, [int]$row, [string]$title = '') {
    $t = New-Tile $id $glyph $accent
    $t.Col = $col; $t.Row = $row; $t.Title = $title
    $DeckTiles[$id] = $t
    $deck.Tiles.Add($t)
}

$deck = New-Object HotkeyDeck.DeckForm
$DeckTiles = [ordered]@{}
Add-Tile 'hdr'       'E706' 'FFC83D' 0 0 'HDR'
Add-Tile 'gpu'       'EC4A' 'FF8C42' 1 0 'Overclock GPU'
Add-Tile 'black'     'E708' 'B4A7FF' 2 0 'Écran noir'
Add-Tile 'side'      'E7F4' '2EC4B6' 3 0 'Écran Philips'
# Barre du bas (Row = -1) : sélecteur des profils audio (un segment par profil)
# puis l'état du micro, centrés ensemble. Le micro est
# vérifié à chaque appui sur son capteur et à l'ouverture du deck : il n'a pas
# besoin d'être cliquable
Add-Tile 'casque'    'E7F6' '4CC2FF' 0 -1 'Casque'
Add-Tile 'enceintes' 'E7F5' '4CC2FF' 1 -1 'Enceintes'
Add-Tile 'mic'       'E720' '3FB950' 2 -1 'Micro'
$DeckTiles.mic.Clickable = $false
$DeckTiles.black.Sub = 'Échap pour quitter'
[HotkeyDeck.MonitorPower]::Refresh($DeckCfg.SideScreen)   # état connu dès la première ouverture

# Un segment par profil : celui qui est actif est allumé
function Update-DeckAudio {
    foreach ($key in 'casque', 'enceintes') {
        $t = $DeckTiles[$key]
        $t.On = $S.Active -eq $key
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

# Dernier état lu (la lecture DDC, ~70 ms, se fait en arrière-plan) : la
# carte suit au rafraîchissement suivant du deck
function Update-DeckSide {
    $t = $DeckTiles.side
    $st = [HotkeyDeck.MonitorPower]::State
    $t.On = $st -eq [HotkeyDeck.MonitorPower]::On
    $t.Sub = if ($st -lt 0) { 'Ne répond pas' } else { '' }
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

# Second écran : allumé ↔ éteint (une veille compte comme éteint : on l'allume)
function Toggle-SideScreen {
    $on = [HotkeyDeck.MonitorPower]::State -ne [HotkeyDeck.MonitorPower]::On
    [HotkeyDeck.MonitorPower]::Set($DeckCfg.SideScreen, $(if ($on) { [HotkeyDeck.MonitorPower]::On } else { [HotkeyDeck.MonitorPower]::Off }))
    Log "Deck : écran $($DeckCfg.SideScreen) $(if ($on) { 'allumé' } else { 'éteint' }) (DDC/CI)"
    Update-DeckSide   # affichage immédiat, confirmé par la relecture
    $deckSideCheck.Stop(); $deckSideCheck.Start()
}

# L'écran ne répond plus au DDC pendant qu'il s'allume : relecture plus tard
$deckSideCheck = New-Object System.Windows.Forms.Timer
$deckSideCheck.Interval = 4000
$deckSideCheck.add_Tick({ Safe {
    $deckSideCheck.Stop()
    [HotkeyDeck.MonitorPower]::Refresh($DeckCfg.SideScreen)
}})

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
        'side'   { Toggle-SideScreen; $deck.Invalidate() }
        'hdr'    { $deck.HideDeck($true); Toggle-Hdr }
        'black'  { $deck.HideDeck($false); Show-BlackScreen }
    }
}

# ============================================================
#  ALERTES (bandeau permanent)
# ============================================================
# Bandeau rouge en haut au centre de l'écran principal, distinct de l'OSD du
# bas (un changement de volume ne le masque pas), transparent aux clics. Une
# ligne par alerte en cours ; il reste affiché tant qu'il en reste une, pour
# ne pas pouvoir la manquer (une OSD de quelques secondes passe inaperçue).
$alertBanner = New-Object HotkeyDeck.OsdForm
$alertBanner.FormBorderStyle = 'None'
$alertBanner.StartPosition   = 'Manual'
$alertBanner.ShowInTaskbar   = $false
$alertBanner.TopMost         = $true
$alertBanner.BackColor       = [System.Drawing.ColorTranslator]::FromHtml('#8B1A1A')
$alertBanner.Opacity         = 0.95
$alertText = New-Object System.Windows.Forms.Label
$alertText.AutoSize  = $false
$alertText.Dock      = 'Fill'
$alertText.TextAlign = 'MiddleCenter'
$alertText.Font      = New-Object System.Drawing.Font('Segoe UI Semibold', 12)
$alertText.ForeColor = [System.Drawing.Color]::White
$alertBanner.Controls.Add($alertText)
$alertBanner.add_HandleCreated({
    $v = 2
    [HotkeyDeck.Native]::DwmSetWindowAttribute($alertBanner.Handle, 33, [ref]$v, 4) | Out-Null
})
$S.Alerts = [ordered]@{ Temp = ''; Sensor = ''; Fans = '' }

# Texte d'une alerte ('' = terminée) ; le bandeau est redimensionné au texte
function Set-Alert([string]$key, [string]$text) {
    if ($S.Alerts[$key] -eq $text) {
        if ($alertBanner.Visible) { $alertBanner.TopMost = $true }
        return
    }
    $S.Alerts[$key] = $text
    $lines = @($S.Alerts.Values | Where-Object { $_ })
    if (-not $lines) { $alertBanner.Hide(); return }
    $alertText.Text = $lines -join "`n"
    $gr = $alertText.CreateGraphics()
    try {
        $sz = [System.Windows.Forms.TextRenderer]::MeasureText($gr, $alertText.Text, $alertText.Font,
            (New-Object System.Drawing.Size(2000, 2000)), [System.Windows.Forms.TextFormatFlags]::NoPadding)
    } finally { $gr.Dispose() }
    $alertBanner.ClientSize = New-Object System.Drawing.Size(
        [Math]::Max((Px 320), $sz.Width + (Px 48)), [Math]::Max((Px 44), $sz.Height + (Px 22)))
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $alertBanner.Location = New-Object System.Drawing.Point(
        [int]($scr.X + [Math]::Floor(($scr.Width - $alertBanner.Width) / 2)), [int]($scr.Y + (Px 24)))
    if (-not $alertBanner.Visible) { $alertBanner.Show() }
    $alertBanner.TopMost = $true
}

# ------------------------------------------------------------
#  Températures
# ------------------------------------------------------------
# Hausse soutenue (pas un pic d'une seconde) : l'alerte dure jusqu'à être
# redescendu sous TempReset. Une mesure absente trop longtemps est signalée
# aussi : sinon l'alerte ne pourrait plus se déclencher, sans qu'on le sache
$S.TempWatch = @{
    CPU = @{ Above = 0; Alerted = $false; Missing = 0 }
    GPU = @{ Above = 0; Alerted = $false; Missing = 0 }
}

function Check-Temps {
    [void][HotkeyDeck.Sensors]::Read()
    $vals = @{ CPU = [HotkeyDeck.Sensors]::Cpu; GPU = [HotkeyDeck.Sensors]::Gpu }
    foreach ($k in 'CPU', 'GPU') {
        $v = $vals[$k]; $w = $S.TempWatch[$k]
        if ([float]::IsNaN($v)) {
            $w.Missing++
            if ($w.Missing -eq $DeckCfg.SensorGrace) { Log "Température : $k non lue depuis $($DeckCfg.SensorGrace * $DeckCfg.TempCheckMs / 1000) s (Afterburner fermé ?)" }
            continue   # état d'alerte inchangé tant qu'on ne sait pas
        }
        if ($w.Missing -ge $DeckCfg.SensorGrace) { Log ("Température : {0} de nouveau lue ({1:0}°)" -f $k, $v) }
        $w.Missing = 0
        if ($v -ge $DeckCfg.TempAlert) {
            $w.Above++
            if ($w.Above -ge $DeckCfg.TempSustain -and -not $w.Alerted) {
                $w.Alerted = $true
                Log ("Température : alerte {0} {1:0}° (seuil {2}°)" -f $k, $v, $DeckCfg.TempAlert)
            }
        } else {
            $w.Above = 0
            if ($w.Alerted -and $v -lt $DeckCfg.TempReset) {
                $w.Alerted = $false
                Log ("Température : {0} revenu à {1:0}°" -f $k, $v)
            }
        }
    }
    # Valeurs du moment, mises à jour à chaque relevé tant que l'alerte dure
    $hot = foreach ($k in 'CPU', 'GPU') {
        if ($S.TempWatch[$k].Alerted) {
            if ([float]::IsNaN($vals[$k])) { "$k ?" } else { '{0} {1:0}°' -f $k, $vals[$k] }
        }
    }
    Set-Alert 'Temp' $(if ($hot) { "⚠  Température  $($hot -join '  ')" } else { '' })
    $blind = @(foreach ($k in 'CPU', 'GPU') { if ($S.TempWatch[$k].Missing -ge $DeckCfg.SensorGrace) { $k } })
    Set-Alert 'Sensor' $(if ($blind) { "⚠  Température $($blind -join ' et ') non surveillée" } else { '' })
}

# ------------------------------------------------------------
#  Ventilateurs GPU
# ------------------------------------------------------------
$S.FanWatch = @{ Above = 0; Shown = $false }

function Check-Fans {
    $pct = [HotkeyDeck.Sensors]::GpuFanMax()
    if ($pct -lt 0) { return }
    $w = $S.FanWatch
    if ($pct -gt $DeckCfg.FanMax) {
        $w.Above++
        if ($w.Above -lt $DeckCfg.TempSustain) { return }
        if (-not $w.Shown) {
            $w.Shown = $true
            Log "Ventilateurs GPU : $pct % (> $($DeckCfg.FanMax) %), bandeau affiché"
        }
        Set-Alert 'Fans' "⚠  Ventilateurs GPU à $pct %"
    } else {
        $w.Above = 0
        if ($w.Shown) {
            $w.Shown = $false
            Log "Ventilateurs GPU : revenus à $pct %, bandeau retiré"
        }
        Set-Alert 'Fans' ''
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
    foreach ($u in 'Update-DeckAudio', 'Update-DeckMic', 'Update-DeckHdr', 'Update-DeckGpu', 'Update-DeckSide') {
        try { & $u } catch { Log "Deck : $u en erreur : $($_.Exception.Message)" }
    }
    # Relit l'état du second écran (sauf changement en cours, pas encore lisible)
    if (-not $deckSideCheck.Enabled) { [HotkeyDeck.MonitorPower]::Refresh($DeckCfg.SideScreen) }
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

# Micro rafraîchi tant que le deck est ouvert
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
    Update-DeckMic
    Update-DeckSide
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
