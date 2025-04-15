package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"path/filepath"
	"time"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/fields"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/clientcmd"
)

var (
	namespace    = flag.String("namespace", "default", "Kubernetes namespace")
	podName      = flag.String("pod", "", "Pod name to watch")
	kubeconfig   = flag.String("kubeconfig", "", "Path to kubeconfig file")
	kubecontext  = flag.String("context", "", "Kubernetes context")
	readyTimeout = flag.Duration("ready-timeout", 300*time.Second, "Timeout for pod readiness")
)

func main() {
	flag.Parse()

	if *podName == "" {
		log.Fatal("Pod name is required")
	}

	if *kubeconfig == "" {
		*kubeconfig = resolveKubeconfig()
	}

	config, err := buildConfig()
	if err != nil {
		log.Fatalf("error building kubeconfig: %v", err)
	}
	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		log.Fatalf("Error creating Kubernetes client: %v", err)
	}

	ctx := context.Background()

	fmt.Printf("Waiting for pod %s to be ready…\n", *podName)
	pod, err := waitForPodReady(ctx, clientset, *namespace, *podName, *readyTimeout)
	if err != nil {
		log.Fatalf("Error waiting for pod readiness: %v", err)
	}

	logCtx, cancelLogs := context.WithCancel(ctx)
	defer cancelLogs()
	go streamPodLogs(logCtx, clientset, *namespace, *podName)

	phase, err := watchPodCompletion(ctx, clientset, *namespace, *podName, pod.ResourceVersion)
	if err != nil {
		log.Fatalf("Error watching pod completion: %v", err)
	}

	if phase == corev1.PodSucceeded {
		fmt.Println("Pod completed successfully")
	} else {
		log.Fatalf("Pod failed (%s)", phase)
	}
}

func buildConfig() (*rest.Config, error) {
	if *kubeconfig == "" {
		*kubeconfig = resolveKubeconfig()
	}

	if *kubeconfig == "" {
		return rest.InClusterConfig()
	}

	return clientcmd.NewNonInteractiveDeferredLoadingClientConfig(
		&clientcmd.ClientConfigLoadingRules{ExplicitPath: *kubeconfig},
		&clientcmd.ConfigOverrides{
			CurrentContext: *kubecontext,
		}).ClientConfig()
}

func resolveKubeconfig() string {
	if kubePath := os.Getenv("KUBECONFIG"); kubePath != "" {
		return kubePath
	}
	defaultPath := filepath.Join(os.Getenv("HOME"), ".kube", "config")
	if _, err := os.Stat(defaultPath); err == nil {
		return defaultPath
	}
	return ""
}

func waitForPodReady(ctx context.Context, client kubernetes.Interface, namespace, podName string, timeout time.Duration) (*corev1.Pod, error) {
	timeoutCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	timeoutSeconds := int64(timeout.Seconds())

	watcher, err := client.CoreV1().Pods(namespace).Watch(ctx, metav1.ListOptions{
		FieldSelector:  fields.OneTermEqualSelector("metadata.name", podName).String(),
		TimeoutSeconds: &timeoutSeconds,
	})
	if err != nil {
		return nil, fmt.Errorf("error watching for pod readiness: %w", err)
	}
	defer watcher.Stop()
	for {
		select {
		case <-timeoutCtx.Done():
			return nil, fmt.Errorf("timeout waiting for pod condition")
		case event, ok := <-watcher.ResultChan():
			if !ok {
				return nil, fmt.Errorf("watch channel closed")
			}

			if event.Type == watch.Error {
				return nil, fmt.Errorf("error watching pod")
			}

			if pod, ok := event.Object.(*corev1.Pod); ok {
				if pod.Status.Phase == corev1.PodSucceeded {
					return pod, nil
				}
				if pod.Status.Phase == corev1.PodFailed {
					return nil, fmt.Errorf("pod failed")
				}
				for _, condition := range pod.Status.Conditions {
					if condition.Type == corev1.PodReady && condition.Status == corev1.ConditionTrue {
						return pod, nil
					}
				}
			}
		}
	}
}

func watchPodCompletion(ctx context.Context, client kubernetes.Interface, namespace, podName, resourceVersion string) (corev1.PodPhase, error) {
	selector := fields.OneTermEqualSelector("metadata.name", podName).String()
	watcher, err := client.CoreV1().Pods(namespace).Watch(ctx, metav1.ListOptions{
		FieldSelector:   selector,
		ResourceVersion: resourceVersion,
	})
	if err != nil {
		return "", fmt.Errorf("error watching pod completion: %w", err)
	}
	defer watcher.Stop()

	for {
		select {
		case <-ctx.Done():
			return "", ctx.Err()
		case event, ok := <-watcher.ResultChan():
			if !ok {
				return "", fmt.Errorf("watch channel closed")
			}

			if event.Type == watch.Error {
				return "", fmt.Errorf("error watching pod")
			}

			if pod, ok := event.Object.(*corev1.Pod); ok {
				if phase := pod.Status.Phase; phase == corev1.PodSucceeded || phase == corev1.PodFailed {
					return phase, nil
				}
			}
		}
	}
}

func streamPodLogs(ctx context.Context, client kubernetes.Interface, namespace, podName string) {
	req := client.CoreV1().Pods(namespace).GetLogs(podName, &corev1.PodLogOptions{
		Follow: true,
	})

	stream, err := req.Stream(ctx)
	if err != nil {
		fmt.Printf("Error opening log stream: %v\n", err)
		return
	}
	defer stream.Close()

	_, err = io.Copy(os.Stdout, stream)
	if err != nil && ctx.Err() == nil {
		fmt.Printf("Error streaming logs: %v\n", err)
	}
}
