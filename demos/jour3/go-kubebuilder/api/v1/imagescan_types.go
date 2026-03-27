/*
Trivy Operator - Version Go avec Kubebuilder
=============================================
Kubebuilder est le framework OFFICIEL des créateurs de Kubernetes (sig-apimachinery).
Il génère le boilerplate : CRD, RBAC, webhooks, controller skeleton.

Concepts clés Go/Kubebuilder vs Python/Kopf :
  - Les types sont des structs Go avec des annotations (markers)
  - Kubebuilder génère le CRD YAML depuis ces structs (code → YAML)
  - Le controller implémente l'interface Reconciler
  - controller-runtime gère le Watch, la queue de travail, les retries

Commandes kubebuilder utilisées pour générer ce projet :
  kubebuilder init --domain formation.local --repo github.com/formation/trivy-operator
  kubebuilder create api --group security --version v1 --kind ImageScan
*/

package v1

import (
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// ---------------------------------------------------------------------------
// Spec : l'état DÉSIRÉ (ce que l'utilisateur veut)
// ---------------------------------------------------------------------------

// ImageScanSpec définit ce que l'utilisateur demande dans son CR
type ImageScanSpec struct {
	// Image Docker à scanner, ex: nginx:1.25
	// +kubebuilder:validation:Required
	Image string `json:"image"`

	// Niveau de sévérité minimum à reporter
	// +kubebuilder:validation:Enum=UNKNOWN;LOW;MEDIUM;HIGH;CRITICAL
	// +kubebuilder:default=HIGH
	Severity string `json:"severity,omitempty"`
}

// ---------------------------------------------------------------------------
// Status : l'état ACTUEL (ce que l'opérateur a observé/fait)
// ---------------------------------------------------------------------------

// VulnerabilityCounts regroupe les compteurs par sévérité
type VulnerabilityCounts struct {
	Critical int `json:"critical"`
	High     int `json:"high"`
	Medium   int `json:"medium"`
	Low      int `json:"low"`
	Total    int `json:"total"`
}

// ImageScanStatus est mis à jour par l'opérateur (jamais par l'utilisateur)
type ImageScanStatus struct {
	// +kubebuilder:validation:Enum=Pending;Scanning;Completed;Failed
	Phase string `json:"phase,omitempty"`

	StartTime      *metav1.Time `json:"startTime,omitempty"`
	CompletionTime *metav1.Time `json:"completionTime,omitempty"`

	Vulnerabilities *VulnerabilityCounts `json:"vulnerabilities,omitempty"`
	Summary         string               `json:"summary,omitempty"`
	JobName         string               `json:"jobName,omitempty"`

	// Conditions : pattern standard Kubernetes pour exprimer l'état
	// Permet à kubectl et aux outils de savoir si la ressource est "Ready"
	Conditions []metav1.Condition `json:"conditions,omitempty"`
}

// ---------------------------------------------------------------------------
// La ressource elle-même
// ---------------------------------------------------------------------------

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Image",type=string,JSONPath=`.spec.image`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`
// +kubebuilder:printcolumn:name="Critical",type=integer,JSONPath=`.status.vulnerabilities.critical`
// +kubebuilder:printcolumn:name="High",type=integer,JSONPath=`.status.vulnerabilities.high`
// +kubebuilder:printcolumn:name="Age",type=date,JSONPath=`.metadata.creationTimestamp`

// ImageScan est la ressource custom définie par notre opérateur
type ImageScan struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ImageScanSpec   `json:"spec,omitempty"`
	Status ImageScanStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// ImageScanList contient une liste d'ImageScan
type ImageScanList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []ImageScan `json:"items"`
}

func init() {
	SchemeBuilder.Register(&ImageScan{}, &ImageScanList{})
}
