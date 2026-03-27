// Package v1 contient les types API pour le groupe security.formation.local
package v1

import (
	"k8s.io/apimachinery/pkg/runtime/schema"
	"sigs.k8s.io/controller-runtime/pkg/scheme"
)

var (
	// GroupVersion identifie notre API group + version
	GroupVersion = schema.GroupVersion{Group: "security.formation.local", Version: "v1"}

	// SchemeBuilder enregistre nos types dans le scheme Kubernetes
	SchemeBuilder = &scheme.Builder{GroupVersion: GroupVersion}

	// AddToScheme permet au manager de connaître nos types
	AddToScheme = SchemeBuilder.AddToScheme
)
