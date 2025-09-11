#!/usr/bin/env bash
# Parcourt chaque sous-dossier contenant un hardhat.config.* et un src/,
# exécute "npx hardhat compile && npx hardhat test",
# puis génère un rapport texte avec les échecs + messages d'erreur.

shopt -s nullglob

ROOT_DIR="$(pwd)"
REPORT_FILE="$ROOT_DIR/hardhat-failures.txt"
MAX_LINES=200   # nb de lignes du message d'erreur à inclure (0 = tout le log)

# On (ré)initialise le rapport ; il ne sera conservé que si des échecs existent
: > "$REPORT_FILE"
report_has_content=0

FAILED_COMPILE=()
FAILED_TEST=()
PASSED=()

echo "== Lancement Hardhat sur chaque module =="

for dir in */ ; do
  # Cible uniquement les "modules" avec un src/ et un hardhat.config.ts/js
  if [[ -d "$dir/src" ]] && compgen -G "$dir/hardhat.config."* > /dev/null; then
    echo ""
    echo "▶▶ $dir"
    pushd "$dir" >/dev/null

    # --- COMPILE ---
    tmp_compile="$(mktemp)"
    # On affiche à l'écran tout en capturant le log dans un fichier temp
    npx hardhat compile 2>&1 | tee "$tmp_compile"
    compile_status=${PIPESTATUS[0]}

    if [[ $compile_status -ne 0 ]]; then
      echo "✖ Compilation échouée dans ${dir%/}"
      FAILED_COMPILE+=("${dir%/}")

      {
        echo "===== ${dir%/} :: COMPILE FAILED ====="
        if (( MAX_LINES > 0 )); then
          echo "(Dernières $MAX_LINES lignes)"
          tail -n "$MAX_LINES" "$tmp_compile"
        else
          cat "$tmp_compile"
        fi
        echo ""
      } >> "$REPORT_FILE"
      report_has_content=1

      rm -f "$tmp_compile"
      popd >/dev/null
      continue
    fi
    rm -f "$tmp_compile"

    # --- TEST ---
    tmp_test="$(mktemp)"
    npx hardhat test 2>&1 | tee "$tmp_test"
    test_status=${PIPESTATUS[0]}

    if [[ $test_status -ne 0 ]]; then
      echo "⚠ Tests échoués dans ${dir%/}"
      FAILED_TEST+=("${dir%/}")

      {
        echo "===== ${dir%/} :: TEST FAILED ====="
        if (( MAX_LINES > 0 )); then
          echo "(Dernières $MAX_LINES lignes)"
          tail -n "$MAX_LINES" "$tmp_test"
        else
          cat "$tmp_test"
        fi
        echo ""
      } >> "$REPORT_FILE"
      report_has_content=1
    else
      echo "✓ OK ${dir%/}"
      PASSED+=("${dir%/}")
    fi
    rm -f "$tmp_test"

    popd >/dev/null
  fi
done

echo ""
echo "================= RÉSUMÉ ================="
((${#PASSED[@]})) && echo "OK: ${PASSED[*]}"

if ((${#FAILED_COMPILE[@]})); then
  echo "Dossiers avec COMPILATION échouée :"
  for d in "${FAILED_COMPILE[@]}"; do echo " - $d"; done
else
  echo "Aucune compilation échouée."
fi

if ((${#FAILED_TEST[@]})); then
  echo "Dossiers avec TESTS échoués (compilation OK) :"
  for d in "${FAILED_TEST[@]}"; do echo " - $d"; done
fi

if [[ $report_has_content -eq 1 ]]; then
  echo ""
  echo "→ Rapport des échecs : $REPORT_FILE"
else
  rm -f "$REPORT_FILE"
  echo ""
  echo "Aucun échec : aucun fichier de rapport généré."
fi

# Code de sortie: bit 1 = compile KO, bit 2 = tests KO
exit_code=0
(( ${#FAILED_COMPILE[@]} > 0 )) && exit_code=$((exit_code | 1))
(( ${#FAILED_TEST[@]}   > 0 )) && exit_code=$((exit_code | 2))
exit $exit_code
