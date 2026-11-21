// Command hubctl is the reference command-line client for the SyncHub
// gateway protocol. It is used for protocol testing (P0) and as a headless
// receiver on servers.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"time"

	"synchub/gateway/internal/client"
	"synchub/gateway/internal/e2e"
	"synchub/gateway/internal/proto"
)

const usage = `hubctl - SyncHub reference client

  hubctl [-config FILE] register -server URL -name NAME (-user U -pass P | -code 123456) [-recv DIR]
  hubctl [-config FILE] devices
  hubctl [-config FILE] pair                  print a 6-digit pairing code for a new device
  hubctl [-config FILE] revoke DEVICE_ID
  hubctl [-config FILE] daemon [-recv DIR]   receive files + resume pending outgoing transfers
  hubctl [-config FILE] send -to NAME|ID [-limit-mbps N] PATH...
  hubctl [-config FILE] resume TRANSFER_ID     resume a pending outgoing transfer in the foreground
  hubctl [-config FILE] outbox                 list pending outgoing transfers

Default config: ~/.synchub/hubctl.json (env HUBCTL_CONFIG overrides).
`

func defaultConfig() string {
	if v := os.Getenv("HUBCTL_CONFIG"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".synchub", "hubctl.json")
}

func die(format string, args ...any) {
	fmt.Fprintf(os.Stderr, "hubctl: "+format+"\n", args...)
	os.Exit(1)
}

func main() {
	gfs := flag.NewFlagSet("hubctl", flag.ExitOnError)
	cfgPath := gfs.String("config", defaultConfig(), "config file")
	gfs.Usage = func() { fmt.Fprint(os.Stderr, usage) }
	_ = gfs.Parse(os.Args[1:])
	args := gfs.Args()
	if len(args) == 0 {
		gfs.Usage()
		os.Exit(2)
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	cmd, rest := args[0], args[1:]
	switch cmd {
	case "register":
		cmdRegister(ctx, *cfgPath, rest)
	case "devices":
		cmdDevices(ctx, mustLoad(*cfgPath))
	case "pair":
		c := mustLoad(*cfgPath)
		pc, err := client.NewAPI(c.Server, c.Token).PairingCode(ctx)
		if err != nil {
			die("%v", err)
		}
		fmt.Printf("配对码 / pairing code: %s  (expires %s)\n", pc.Code, pc.ExpiresAt.Local().Format("15:04:05"))
	case "revoke":
		if len(rest) != 1 {
			die("usage: revoke DEVICE_ID")
		}
		c := mustLoad(*cfgPath)
		if err := client.NewAPI(c.Server, c.Token).DeleteDevice(ctx, rest[0]); err != nil {
			die("%v", err)
		}
		fmt.Println("revoked", rest[0])
	case "daemon":
		cmdDaemon(ctx, *cfgPath, rest)
	case "send":
		cmdSend(ctx, mustLoad(*cfgPath), rest)
	case "resume":
		if len(rest) != 1 {
			die("usage: resume TRANSFER_ID")
		}
		runSendMode(ctx, mustLoad(*cfgPath), rest[0], 0)
	case "outbox":
		cmdOutbox(mustLoad(*cfgPath))
	default:
		gfs.Usage()
		os.Exit(2)
	}
}

func mustLoad(path string) *client.Config {
	c, err := client.LoadConfig(path)
	if err != nil {
		die("load config %s: %v", path, err)
	}
	return c
}

func defaultRecvDir() string {
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "windows":
		if st, err := os.Stat(`K:\`); err == nil && st.IsDir() {
			return `K:\跨端传输文件`
		}
		return filepath.Join(home, "Downloads", "跨端传输文件")
	case "darwin":
		return filepath.Join(home, "Desktop", "跨端传输文件")
	default:
		return filepath.Join(home, "跨端传输文件")
	}
}

func cmdRegister(ctx context.Context, cfgPath string, args []string) {
	fs := flag.NewFlagSet("register", flag.ExitOnError)
	server := fs.String("server", "", "gateway base URL, e.g. https://020814.xyz/gw")
	name := fs.String("name", "", "device name")
	user := fs.String("user", os.Getenv("SYNCHUB_USER"), "account user")
	pass := fs.String("pass", os.Getenv("SYNCHUB_PASSWORD"), "account password")
	code := fs.String("code", "", "pairing code from an existing device")
	recv := fs.String("recv", defaultRecvDir(), "receive directory")
	platform := fs.String("platform", runtime.GOOS, "platform label")
	_ = fs.Parse(args)
	if *server == "" || *name == "" || (*code == "" && (*user == "" || *pass == "")) {
		die("register needs -server, -name and either -code or -user/-pass")
	}
	priv, err := e2e.GenerateKey()
	if err != nil {
		die("%v", err)
	}
	pub := e2e.EncodePublic(priv.PublicKey())
	resp, err := client.Register(ctx, *server, *user, *pass, *code, proto.RegisterRequest{Name: *name, Platform: *platform, PublicKey: pub})
	if err != nil {
		die("register: %v", err)
	}
	c := &client.Config{
		Server: strings.TrimRight(*server, "/"), DeviceID: resp.DeviceID, Token: resp.Token,
		Name: *name, Platform: *platform, PrivateKey: e2e.EncodePrivate(priv),
		RecvDir: *recv, StateDir: filepath.Join(filepath.Dir(cfgPath), "state-"+resp.DeviceID), AutoAccept: true,
	}
	if err := c.Save(cfgPath); err != nil {
		die("save config: %v", err)
	}
	fmt.Printf("registered %q as %s\n  key fingerprint: %s\n  config: %s\n  receive dir: %s\n", *name, resp.DeviceID, e2e.Fingerprint(pub), cfgPath, *recv)
}

func cmdDevices(ctx context.Context, c *client.Config) {
	resp, err := client.NewAPI(c.Server, c.Token).Devices(ctx)
	if err != nil {
		die("%v", err)
	}
	fmt.Printf("%-18s %-20s %-8s %-7s %-14s %s\n", "ID", "NAME", "PLATFORM", "ONLINE", "FINGERPRINT", "LAST SEEN")
	for _, d := range resp.Devices {
		me := ""
		if d.ID == resp.Self {
			me = " (this device)"
		}
		on := "-"
		if d.Online {
			on = "yes"
		}
		fmt.Printf("%-18s %-20s %-8s %-7s %-14s %s%s\n", d.ID, d.Name, d.Platform, on, e2e.Fingerprint(d.PublicKey), d.LastSeen.Local().Format("01-02 15:04"), me)
	}
}

func printProgress(p client.Progress) {
	pct := 100.0
	if p.Total > 0 {
		pct = 100 * float64(p.Done) / float64(p.Total)
	}
	arrow := "→"
	if p.Direction == "recv" {
		arrow = "←"
	}
	fmt.Printf("  [%s] %s %s %s  %5.1f%%  %s / %s  %s/s  via %s\n", p.TransferID, arrow, p.Peer, p.Title, pct,
		client.Human(p.Done), client.Human(p.Total), client.Human(int64(p.BytesPerS)), p.Route)
}

func printResult(r client.Result) {
	if r.OK {
		fmt.Printf("✔ [%s] %s complete\n", r.TransferID, r.Direction)
		for _, s := range r.Saved {
			fmt.Printf("    %s\n", s)
		}
	} else {
		fmt.Printf("✘ [%s] %s failed: %s\n", r.TransferID, r.Direction, r.Err)
	}
}

func cmdDaemon(ctx context.Context, cfgPath string, args []string) {
	fs := flag.NewFlagSet("daemon", flag.ExitOnError)
	recv := fs.String("recv", "", "override receive directory")
	workers := fs.Int("workers", 4, "parallel chunk streams")
	lan := fs.String("lan", fmt.Sprintf(":%d", client.DefaultLANPort), "direct LAN receiver listen address (\"\" to disable)")
	_ = fs.Parse(args)
	c := mustLoad(cfgPath)
	if *recv != "" {
		c.RecvDir = *recv
	}
	a, err := client.NewAgent(c, client.Options{Receive: true, LANListen: *lan, Workers: *workers, OnProgress: printProgress, OnResult: printResult})
	if err != nil {
		die("%v", err)
	}
	fmt.Printf("daemon: %s (%s), receiving into %s\n", c.Name, c.DeviceID, c.RecvDir)
	_, err = a.Run(ctx)
	if err != nil && !errors.Is(err, context.Canceled) {
		die("%v", err)
	}
}

func resolveDevice(ctx context.Context, c *client.Config, q string) (proto.DeviceInfo, error) {
	resp, err := client.NewAPI(c.Server, c.Token).Devices(ctx)
	if err != nil {
		return proto.DeviceInfo{}, err
	}
	var hits []proto.DeviceInfo
	for _, d := range resp.Devices {
		if d.ID == resp.Self {
			continue
		}
		if d.ID == q || strings.EqualFold(d.Name, q) {
			return d, nil
		}
		if strings.Contains(strings.ToLower(d.Name), strings.ToLower(q)) {
			hits = append(hits, d)
		}
	}
	if len(hits) == 1 {
		return hits[0], nil
	}
	if len(hits) > 1 {
		return proto.DeviceInfo{}, fmt.Errorf("%q matches %d devices, be more specific", q, len(hits))
	}
	return proto.DeviceInfo{}, fmt.Errorf("no device matches %q", q)
}

func cmdSend(ctx context.Context, c *client.Config, args []string) {
	fs := flag.NewFlagSet("send", flag.ExitOnError)
	to := fs.String("to", "", "target device name or id")
	limit := fs.Float64("limit-mbps", 0, "limit send rate (MiB/s), 0 = unlimited")
	_ = fs.Parse(args)
	if *to == "" || fs.NArg() == 0 {
		die("usage: send -to DEVICE PATH...")
	}
	dev, err := resolveDevice(ctx, c, *to)
	if err != nil {
		die("%v", err)
	}
	a, err := client.NewAgent(c, client.Options{})
	if err != nil {
		die("%v", err)
	}
	fmt.Printf("hashing %d path(s)…\n", fs.NArg())
	last := time.Now()
	e, err := a.Enqueue(fs.Args(), dev.ID, func(done, total int64) {
		if time.Since(last) > time.Second {
			last = time.Now()
			fmt.Printf("  hashed %s / %s\n", client.Human(done), client.Human(total))
		}
	})
	if err != nil {
		die("%v", err)
	}
	fmt.Printf("queued %s: %q, %d file(s) → %s%s\n", e.TransferID, e.Title, len(e.Files), dev.Name, map[bool]string{true: "", false: " (offline - will send when it comes online)"}[dev.Online])
	runSendMode(ctx, c, e.TransferID, int64(*limit*(1<<20)))
}

func runSendMode(ctx context.Context, c *client.Config, tid string, limit int64) {
	a, err := client.NewAgent(c, client.Options{OnlyTransfer: tid, LimitBPS: limit, OnProgress: printProgress})
	if err != nil {
		die("%v", err)
	}
	a.HoldLease(ctx, tid)
	r, err := a.Run(ctx)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			fmt.Printf("\ninterrupted; transfer %s stays queued. Resume with `hubctl resume %s` or let `hubctl daemon` finish it.\n", tid, tid)
			return
		}
		die("%v", err)
	}
	printResult(*r)
	if !r.OK {
		os.Exit(1)
	}
}

func cmdOutbox(c *client.Config) {
	ents, _ := filepath.Glob(filepath.Join(c.StateDir, "outbox", "*.json"))
	if len(ents) == 0 {
		fmt.Println("outbox empty")
		return
	}
	for _, p := range ents {
		fmt.Println(strings.TrimSuffix(filepath.Base(p), ".json"))
	}
}
