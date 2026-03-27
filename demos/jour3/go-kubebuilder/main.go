/*
Point d'entrée de l'opérateur Go.
Le Manager de controller-runtime orchestre tout :
  - Cache des objets Kubernetes (évite de surcharger l'API server)
  - Boucle d'événements (informers + work queue)
  - Health checks (/healthz, /readyz)
  - Leader election (une seule instance active en HA)
*/
package main

import (
	"flag"
	"os"

	batchv1 "k8s.io/api/batch/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/log/zap"

	securityv1 "github.com/formation/trivy-operator/api/v1"
	"github.com/formation/trivy-operator/internal/controller"
)

var scheme = runtime.NewScheme()

func init() {
	// Enregistrer les types Kubernetes standards (Pod, Job, etc.)
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(batchv1.AddToScheme(scheme))
	// Enregistrer nos types custom (ImageScan)
	utilruntime.Must(securityv1.AddToScheme(scheme))
}

func main() {
	var metricsAddr string
	var enableLeaderElection bool
	var probeAddr string

	flag.StringVar(&metricsAddr, "metrics-bind-address", ":8080", "Adresse du serveur de métriques")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":8081", "Adresse des health probes")
	flag.BoolVar(&enableLeaderElection, "leader-elect", false,
		"Activer le leader election pour la haute disponibilité")
	flag.Parse()

	ctrl.SetLogger(zap.New(zap.UseDevMode(true)))
	logger := ctrl.Log.WithName("main")

	// Créer le Manager : cerveau de l'opérateur
	mgr, err := ctrl.NewManager(ctrl.GetConfigOrDie(), ctrl.Options{
		Scheme:                 scheme,
		MetricsBindAddress:     metricsAddr,
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         enableLeaderElection,
		LeaderElectionID:       "trivy-operator.formation.local",
	})
	if err != nil {
		logger.Error(err, "Impossible de créer le Manager")
		os.Exit(1)
	}

	// Enregistrer notre controller dans le Manager
	if err = (&controller.ImageScanReconciler{
		Client: mgr.GetClient(),
		Scheme: mgr.GetScheme(),
	}).SetupWithManager(mgr); err != nil {
		logger.Error(err, "Impossible d'initialiser le controller ImageScan")
		os.Exit(1)
	}

	// Health checks exposés à Kubernetes (liveness/readiness probes)
	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		logger.Error(err, "Impossible d'ajouter le healthz check")
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		logger.Error(err, "Impossible d'ajouter le readyz check")
		os.Exit(1)
	}

	logger.Info("Démarrage du Trivy Operator")

	// Lancer le Manager : démarre le cache, les informers, la boucle d'événements
	// Bloque jusqu'à réception d'un signal SIGTERM/SIGINT
	if err := mgr.Start(ctrl.SetupSignalHandler()); err != nil {
		logger.Error(err, "Erreur au démarrage du Manager")
		os.Exit(1)
	}
}
