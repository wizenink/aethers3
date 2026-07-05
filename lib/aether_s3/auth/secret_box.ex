defmodule AetherS3.Auth.SecretBox do
  @moduledoc """
  Authenticated AES-256-GCM encryption for secrets stored at rest in Khepri.
  Blob layout: <<iv::12 bytes, tag::16 bytes, ciphertext::binary>>
  """

  @iv_bytes 12
  @tag_bytes 16

  def derive_key(passphrase) when is_binary(passphrase) do
    :crypto.hash(:sha256, passphrase)
  end

  def encrypt(plaintext, key) when byte_size(key) == 32 do
    iv = :crypto.strong_rand_bytes(@iv_bytes)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, plaintext, _aad = "", true)

    iv <> tag <> ciphertext
  end

  def decrypt(blob, key) when byte_size(key) == 32 do
    case blob do
      <<iv::binary-size(@iv_bytes), tag::binary-size(@tag_bytes), ciphertext::binary>> ->
        case :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, ciphertext, "", tag, false) do
          :error -> :error
          plaintext when is_binary(plaintext) -> {:ok, plaintext}
        end

      _ ->
        :error
    end
  end
end
