#!/bin/bash

# TODO (in priority order)
# Improve SHA256 checks usage for smarter decision making
# Smart resume: only if hfdl used in the repo before
# Friendly cli interface (inputs, branches, outputs)
# Queue system (append downloads after script execution)
# Parallel/multithreaded downloads
# GGUF support (quant selection)
# Regex/fixed string folder/file exclusions
# Download datasets and other types of repos
# Git lfs pull type updates

config() {
  models=(meta-llama/Meta-Llama-3-8B-Instruct)
  branch='' # can be omitted to use the default branch
  base_path="$HOME/storage/gpu-models" # where to download the models
  screen='llm-download' # gnu screen name, can be edited for parallel use
  hf_token='' # using HF_TOKEN from env if empty
}

main() {
  [ -n "$1" ] && models=("$@")
  [ -z "$models" ] && echo -e '\e[31m-- Error: No model provided\e[0m' && exit
  [ -z "$branch" ] && branch='main'
  [ -z "$hf_token" ] && [ -n "$HF_TOKEN" ] && hf_token="$HF_TOKEN"

  get_screen "$@"
  cd "$(dirname "$0")"
  mkdir -p "$base_path"
  trap 'cleanup; exit' 2 3

  for model in "${models[@]}"; do
    echo -e "\n\e[34m-- Getting model '$model'...\e[0m"
    model_path="$base_path/${model//\//_}"
    get_repo || continue
    delay_print='\n\e[36m-- Downloading all LFS files...\e[0m'
    download_folder '' || continue
    sha256_integrity_check "$model" "$model_path" || fail
  done
  success
}

get_repo() {
  prepare_repo && setup_repo && handle_repo_errors
  return "$?"
}

git_clone_pull() {
  local repo_dir="${model//\//_}"
  local url="https://huggingface.co/$model"

  if [ -z "$hf_token" ]; then
    local html_page=$(curl -m 10 "$url/tree/main" 2>/dev/null)
    if [ "$?" != 0 ]; then
      echo -e '\e[31m-- Failed to clone/update git repo. Trying again in 5 sec.\e[0m'
      sleep 5
      get_repo
      return "$?"
    fi
  fi

  if [ -n "$hf_token" ] || ! grep -Fq '<button class="text-sm md:' <<< "$html_page"; then
    if [ -z "$hf_token" ]; then
      echo -e "\e[31m-- Repository is private and HF_TOKEN was not provided\e[0m"
      fail
    fi
    GIT_ASKPASS="$(mktemp)"
    echo "echo $hf_token" > "$GIT_ASKPASS"
    chmod +x "$GIT_ASKPASS"
  fi

  if [ -d "$base_path/$repo_dir/.git" ]; then
    GIT_ASKPASS="$GIT_ASKPASS" git -C "$base_path/$repo_dir" pull
  else
    GIT_ASKPASS="$GIT_ASKPASS" git -C "$base_path" clone "$url" "$repo_dir"
  fi
  return "$?"
}

prepare_repo() {
  [ -d "$model_path" ] || mkdir -p "$model_path"
  if [ -z $(find "$model_path" -maxdepth 0 -empty) ] && [ ! -d "$model_path/.git" ]; then
    echo -e '\e[31m-- Target directory for model is non empty and non git\e[0m'
    fail
  fi

  echo '-- Cloning/updating repository...'
  git_clone_pull
  if [ "$?" != 0 ]; then
    echo -e '\e[31m-- Failed to clone/update git repo. Trying again in 5 sec.\e[0m'
    sleep 5
    get_repo
    return "$?"
  fi

  echo -e '\n\e[36m-- Checking SHA256 integrity for all non LFS files...\e[0m'
  git -C "$model_path" fsck
  if [ "$?" != 0 ]; then
    echo -e '\e[31m-- Model integrity is incorrect. Deleting...\e[0m'
    force_delete
  fi
  mapfile -t deleted_files < <(git -C "$model_path" ls-files --deleted)
  for deleted_file in "${deleted_files[@]}"; do
    git -C "$model_path" restore "$deleted_file"
  done
}

setup_repo() {
  if [ ! -d "$model_path" ]; then
    git -C "$model_path" checkout "$branch"
    if [ "$?" = 0 ]; then
      echo -e "\e[32m-- Switched to branch '$branch'...\e[0m"
    else
      echo -e "\e[31m-- Failed to switch to branch '$branch'.\e[0m"
      force_delete
      fail
    fi
  fi
  echo -e '\e[32m-- Non LFS files are ready.\e[0m'
}

handle_repo_errors() {
  cpu_models=$(find "$model_path" -iname '*ggml*' -or -iname '*gguf*')
  if [ -n "$cpu_models" ]; then
    echo -e '\e[31m-- GGUF/GGML model detected. Abording.\e[0m'
    fail
  fi
  echo -e '\e[32m-- Model is non GGUF/GGML.\e[0m'
}

download_folder() {
  local folder="$1"
  for object in $(ls -A1 "$model_path/$folder"); do
    object="$folder/$object"
    object="${object#/}"
    file_path="$model_path/$object"
    [ "$object" = '.git' ] && continue
    if [ -d "$file_path" ]; then
      download_folder "$object"
    else
      header=$(head -c 40 "$file_path" | base64 -w 0)
      lfs_tag=$(echo -n 'version https://git-lfs.github.com/spec/' | base64 -w 0)
      if [ "$header" == "$lfs_tag" ] || [ ! -s "$file_path" ]; then
        download_file
      fi
    fi
  done
  return 0
}

download_file() {
  local file_url="https://huggingface.co/$model/resolve/$branch/$object"
  local local_size=$(stat -c "%s" "$file_path")
  local resume=""

  [ -n "$delay_print" ] && echo -e "$delay_print" && delay_print=''
  if [ "$local_size" -lt 1024 ]; then
    local remote_size=$(tail -n 1 "$file_path")
    remote_size=$(numfmt --to=iec-i --format="%.2fB" <<< "${remote_size##* }" 2>/dev/null || echo 'Unknown size')
    echo "-- Downloading LFS file: ${file_path/$HOME/\~} (${remote_size})"
  else
    echo "-- Continue downloading LFS file: ${file_path/$HOME/\~}"
    resume='-c'
  fi

  wget $resume "$file_url" -O "$file_path" \
    --quiet --show-progress --tries=50 --waitretry=10 \
    --header="Authorization: Bearer $hf_token"

  if [ "$?" != 0 ]; then
    echo -e "\e[31m-- Error: Failed to download the file ${file_path/$HOME/\~}\e[0m"
    echo -e '\e[31m-- Make sure that you have an Internet connection and authorized access (HF_TOKEN?)\e[0m'
    fail
  fi
}

force_delete() {
  if [ -z "$model_path" ] || [ "$model_path" = '/' ]; then
    echo -e '\e[31m-- Unknown error.\e[0m'
    fail
  fi
  read -p $'\e[31m-- About to force-delete '"$model_path"$'. Continue? (y/n)\e[0m ' x
  if [ "$x" = y ] || [ "$x" = yes ]; then
    rm -rf "$model_path"
  fi
}

sha256_integrity_check() {
  local repo="$1"
  local path=$(readlink -f "$2")
  local mismatches=()

  if [ ! -d "$path/.git" ]; then
    echo -e "\e[31m-- Error: No git repository found at '$path' \e[0m"
    return 1
  fi

  echo -e '\n\e[36m-- Checking SHA256 integrity for all LFS files\e[0m'
  while read -r hash _ file; do
    local file_path="${path%/}/$file"
    local file_name="${file/$HOME/\~}"
    echo -en "\e[s-- Checking $file_name..."
    if [ -f "$file_path" ]; then
      local calculated_hash=$(sha256sum "$file_path" | cut -d ' ' -f 1)
      if [ "$hash" = "$calculated_hash" ]; then
        echo -e "\e[u-- Hash matches for $file_name"
      else
        echo -e "\e[u\e[31m-- Hash mismatch for $file_name\e[0m"
        echo -e "\e[36m-> $hash\e[0m"
        echo -e "\e[36m-< $calculated_hash\e[0m"
        mismatches+=("$file_path")
      fi
    else
      echo -e "\e[u\e[33mFile not found: $file_name\e[0m"
    fi
  done < <(git -C "$path" lfs ls-files --long)

  if [ -n "$mismatches" ]; then
    echo -e "\n\e[31m-- Hash mismatch detected inside of $repo\e[0m"
    echo -e '\e[36m-- BEGIN list of corrupted files\e[0m'
    printf '%s\n' "${mismatches}"
    echo -e '\e[36m-- END list of corrupted files\e[0m'
    return 1
  else
    echo -e "\e[32m-- Repository integrity verified\e[0m"
    return 0
  fi
}

get_screen() {
  if [ -z "$STY" ]; then
    screen -ls | grep -q "$screen" && \
    echo 'Process already running.' && exit 1
    check_deps screen git wget || exit 1
    echo "Launching the $screen screen..."
    screen -mS "$screen" -L -Logfile "${0%.*}.log" bash "$0" "$@"
    exit 0
  fi
}

check_deps() {
  if dpkg-query --version >/dev/null 2>&1; then
    readarray -t packages <<< $(dpkg-query -W -f='${Package}\n')
  elif pacman -V >/dev/null 2>&1; then
    readarray -t packages <<< $(pacman -Qq)
  else
    echo -e '\e[33m-- The system does not have dpkg or pacman intalled, proceeding without dependency checks.\e[33m'
    return
  fi

  missing=()
  for dependency in "$@"; do
    found=''
    IFS="/" read -ra dependencies <<< "$dependency"
    for dep in "${dependencies[@]}"; do
      for package in "${packages[@]}"; do
        if [ "$package" = "$dep" ]; then
          found=true
          break 2
        fi
      done
    done
    [ -z "$found" ] && missing+=("$dependency")
  done

  if [ -n "$missing" ]; then
    echo -e "\e[31m-- Missing dependencies: ${missing[@]}\e[0m"
    return 1
  fi
}

cleanup() {
  if [ -f "$GIT_ASKPASS" ]; then
    rm -f "$GIT_ASKPASS"
  fi
}

fail() { cleanup; read -p $'\n\e[31mFailed. Press any key to continue.\e[0m'; exit 1; }
success() { cleanup; read -p $'\n\e[32mSuccess. Press any key to continue.\e[0m'; exit 0; }

config
main "$@"
