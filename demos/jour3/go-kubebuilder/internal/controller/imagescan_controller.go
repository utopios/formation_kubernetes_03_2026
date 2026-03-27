/*
Trivy Operator - Controller Go (Kubebuilder)
============================================

C'est ici que vit la BOUCLE DE RÉCONCILIATION.

Le pattern est toujours le même :
  1. Lire l'état actuel du cluster
  2. Comparer avec l'état désiré (le Spec du CR)
  3. Agir pour combler l'écart
  4. Mettre à jour le Status
  5. Retourner (controller-runtime relancera si nécessaire)

La fonction Reconcile est appelée par controller-runtime :
  - À la création/modification/suppression du CR
  - Quand un Job associé change d'état
  - En cas d'erreur (avec backoff exponentiel automatique)
  - À la reprise après un restart de l'opérateur (idempotence obligatoire !)
*/

package controller

import (
	"context"
	"encoding/json"
	"fmt"
	"time"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/log"

	securityv1 "github.com/formation/trivy-operator/api/v1"
)

// ImageScanReconciler implémente l'interface Reconciler de controller-runtime
// Il contient le client Kubernetes et le scheme (registre des types)
type ImageScanReconciler struct {
	client.Client
	Scheme *runtime.Scheme
}

// ---------------------------------------------------------------------------
// Reconcile : le cœur de l'opérateur
// Appelé par controller-runtime à chaque événement pertinent
// ---------------------------------------------------------------------------

// +kubebuilder:rbac:groups=security.formation.local,resources=imagescans,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=security.formation.local,resources=imagescans/status,verbs=get;update;patch
// +kubebuilder:rbac:groups=batch,resources=jobs,verbs=get;list;watch;create;update;patch;delete
// +kubebuilder:rbac:groups=core,resources=pods/log,verbs=get

func (r *ImageScanReconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	// -----------------------------------------------------------------------
	// ÉTAPE 1 : Lire le CR ImageScan depuis le cluster
	// -----------------------------------------------------------------------
	scan := &securityv1.ImageScan{}
	if err := r.Get(ctx, req.NamespacedName, scan); err != nil {
		if errors.IsNotFound(err) {
			// CR supprimé entre le moment où l'event a été mis en queue et maintenant
			// C'est normal, pas d'erreur
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	logger.Info("Réconciliation", "image", scan.Spec.Image, "phase", scan.Status.Phase)

	// -----------------------------------------------------------------------
	// ÉTAPE 2 : Logique de réconciliation selon la phase actuelle
	// -----------------------------------------------------------------------
	switch scan.Status.Phase {

	case "", "Pending":
		// Nouvelle demande de scan → créer le Job Trivy
		return r.startScan(ctx, scan)

	case "Scanning":
		// Scan en cours → vérifier si le Job est terminé
		return r.checkScanProgress(ctx, scan)

	case "Completed", "Failed":
		// Rien à faire, scan terminé
		return ctrl.Result{}, nil
	}

	return ctrl.Result{}, nil
}

// ---------------------------------------------------------------------------
// startScan : crée le Job Trivy et passe la phase à "Scanning"
// ---------------------------------------------------------------------------
func (r *ImageScanReconciler) startScan(ctx context.Context, scan *securityv1.ImageScan) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	jobName := fmt.Sprintf("trivy-scan-%s", scan.Name)
	job := r.buildTrivyJob(jobName, scan)

	// SetControllerReference : lie le Job à l'ImageScan.
	// Quand l'ImageScan est supprimé, le Job l'est automatiquement aussi (garbage collection).
	if err := ctrl.SetControllerReference(scan, job, r.Scheme); err != nil {
		return ctrl.Result{}, err
	}

	logger.Info("Création du Job Trivy", "job", jobName)
	if err := r.Create(ctx, job); err != nil {
		if !errors.IsAlreadyExists(err) {
			return ctrl.Result{}, err
		}
		// Job déjà existant (restart de l'opérateur) → on continue
		logger.Info("Job déjà existant, on continue", "job", jobName)
	}

	// Mettre à jour le Status (sous-ressource séparée en Kubernetes)
	now := metav1.Now()
	scan.Status.Phase = "Scanning"
	scan.Status.StartTime = &now
	scan.Status.JobName = jobName

	if err := r.Status().Update(ctx, scan); err != nil {
		return ctrl.Result{}, err
	}

	// Recheck dans 30 secondes pour voir si le Job est terminé
	return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

// ---------------------------------------------------------------------------
// checkScanProgress : vérifie si le Job est terminé et lit les résultats
// ---------------------------------------------------------------------------
func (r *ImageScanReconciler) checkScanProgress(ctx context.Context, scan *securityv1.ImageScan) (ctrl.Result, error) {
	logger := log.FromContext(ctx)

	job := &batchv1.Job{}
	jobKey := types.NamespacedName{Name: scan.Status.JobName, Namespace: scan.Namespace}

	if err := r.Get(ctx, jobKey, job); err != nil {
		if errors.IsNotFound(err) {
			scan.Status.Phase = "Failed"
			scan.Status.Summary = "Job introuvable"
			_ = r.Status().Update(ctx, scan)
			return ctrl.Result{}, nil
		}
		return ctrl.Result{}, err
	}

	// Job réussi ?
	if job.Status.Succeeded > 0 {
		logger.Info("Job terminé, lecture des résultats")

		counts, err := r.readTrivyResults(ctx, scan.Status.JobName, scan.Namespace)
		if err != nil {
			logger.Error(err, "Erreur lecture résultats")
			counts = &securityv1.VulnerabilityCounts{}
		}

		now := metav1.Now()
		scan.Status.Phase = "Completed"
		scan.Status.CompletionTime = &now
		scan.Status.Vulnerabilities = counts
		scan.Status.Summary = fmt.Sprintf(
			"Scan terminé: %d critical, %d high, %d total",
			counts.Critical, counts.High, counts.Total,
		)

		logger.Info(scan.Status.Summary)
		return ctrl.Result{}, r.Status().Update(ctx, scan)
	}

	// Job échoué ?
	if job.Status.Failed >= 3 {
		scan.Status.Phase = "Failed"
		scan.Status.Summary = "Échec du scan après 3 tentatives"
		return ctrl.Result{}, r.Status().Update(ctx, scan)
	}

	// Job toujours en cours → recheck dans 30s
	return ctrl.Result{RequeueAfter: 30 * time.Second}, nil
}

// ---------------------------------------------------------------------------
// buildTrivyJob : construit le Job Kubernetes pour Trivy
// ---------------------------------------------------------------------------
func (r *ImageScanReconciler) buildTrivyJob(name string, scan *securityv1.ImageScan) *batchv1.Job {
	backoffLimit := int32(3)
	ttl := int32(300) // Auto-supprimé après 5 min

	return &batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      name,
			Namespace: scan.Namespace,
			Labels:    map[string]string{"app": "trivy-operator"},
		},
		Spec: batchv1.JobSpec{
			BackoffLimit:            &backoffLimit,
			TTLSecondsAfterFinished: &ttl,
			Template: corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{
					RestartPolicy: corev1.RestartPolicyNever,
					Containers: []corev1.Container{
						{
							Name:  "trivy",
							Image: "aquasec/trivy:latest",
							// Trivy scanne l'image et sort le JSON sur stdout
							Command: []string{
								"trivy", "image",
								"--format", "json",
								"--severity", scan.Spec.Severity,
								scan.Spec.Image,
							},
						},
					},
				},
			},
		},
	}
}

// ---------------------------------------------------------------------------
// readTrivyResults : parse le JSON Trivy depuis les logs du Pod
// ---------------------------------------------------------------------------
func (r *ImageScanReconciler) readTrivyResults(ctx context.Context, jobName, namespace string) (*securityv1.VulnerabilityCounts, error) {
	// Trouver le pod du job
	podList := &corev1.PodList{}
	if err := r.List(ctx, podList,
		client.InNamespace(namespace),
		client.MatchingLabels{"job-name": jobName},
	); err != nil {
		return nil, err
	}

	if len(podList.Items) == 0 {
		return nil, fmt.Errorf("aucun pod trouvé pour le job %s", jobName)
	}

	// En production : lire via l'API logs ou un PVC partagé
	// Pour la démo, on simule la lecture du JSON
	// (la vraie implémentation utilise clientset.CoreV1().Pods().GetLogs())
	return parseTrivyReport([]byte(`{"Results":[]}`))
}

// parseTrivyReport : parse le JSON de sortie de Trivy
func parseTrivyReport(data []byte) (*securityv1.VulnerabilityCounts, error) {
	var report struct {
		Results []struct {
			Vulnerabilities []struct {
				Severity string `json:"Severity"`
			} `json:"Vulnerabilities"`
		} `json:"Results"`
	}

	if err := json.Unmarshal(data, &report); err != nil {
		return nil, err
	}

	counts := &securityv1.VulnerabilityCounts{}
	for _, result := range report.Results {
		for _, vuln := range result.Vulnerabilities {
			switch vuln.Severity {
			case "CRITICAL":
				counts.Critical++
			case "HIGH":
				counts.High++
			case "MEDIUM":
				counts.Medium++
			case "LOW":
				counts.Low++
			}
			counts.Total++
		}
	}

	return counts, nil
}

// ---------------------------------------------------------------------------
// SetupWithManager : enregistre le controller dans le manager
// C'est ici qu'on dit à controller-runtime quels événements nous intéressent
// ---------------------------------------------------------------------------
func (r *ImageScanReconciler) SetupWithManager(mgr ctrl.Manager) error {
	return ctrl.NewControllerManagedBy(mgr).
		// Surveiller les ImageScan
		For(&securityv1.ImageScan{}).
		// Surveiller aussi les Jobs possédés par un ImageScan (via OwnerReference)
		// Quand un Job change d'état → Reconcile est appelé pour l'ImageScan parent
		Owns(&batchv1.Job{}).
		Complete(r)
}
