package main

import (
	"context"
	"errors"
	"log"
	"os"

	"github.com/boinkor-net/tsnsrv"
	"github.com/peterbourgon/ff/v3/ffcli"
)

func main() {
	services, cmd, err := tsnsrv.TailnetSrvsFromArgs(os.Args)
	if err != nil {
		log.Fatalf("Invalid CLI usage. Errors:\n%v\n\n%v", errors.Unwrap(err), ffcli.DefaultUsageFunc(cmd))
	}

	// Use orchestrator for both single and multi-service modes
	orchestrator := tsnsrv.NewOrchestrator(services)
	if err := orchestrator.Run(context.Background()); err != nil {
		log.Fatal(err)
	}
}
