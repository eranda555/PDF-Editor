package com.hundredpercentpdf.hundred_percent_pdf

import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyInfo
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.Signature
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec

class DeviceIdentity {
    private val alias="pdf_suite_device_v1"
    private fun store(): KeyStore {
        val store=KeyStore.getInstance("AndroidKeyStore");store.load(null)
        if(!store.containsAlias(alias)) {
            val generator=KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC,"AndroidKeyStore")
            generator.initialize(KeyGenParameterSpec.Builder(alias,KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY)
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(KeyProperties.DIGEST_SHA256).build())
            generator.generateKeyPair()
        }
        val privateKey=store.getKey(alias,null)
        val info=KeyFactory.getInstance(privateKey.algorithm,"AndroidKeyStore").getKeySpec(privateKey,KeyInfo::class.java)
        val hardware=if(Build.VERSION.SDK_INT>=31) info.securityLevel==KeyProperties.SECURITY_LEVEL_TRUSTED_ENVIRONMENT || info.securityLevel==KeyProperties.SECURITY_LEVEL_STRONGBOX || info.securityLevel==KeyProperties.SECURITY_LEVEL_UNKNOWN_SECURE
            else isHardware(info)
        check(hardware){"Hardware-backed signing is required"}
        return store
    }
    @Suppress("DEPRECATION")
    private fun isHardware(info:KeyInfo)=info.isInsideSecureHardware
    fun publicKey():String {
        val key=store().getCertificate(alias).publicKey as ECPublicKey
        fun fixed(bytes:ByteArray):ByteArray=ByteArray(32).also { output ->
            val start=maxOf(0,bytes.size-32);System.arraycopy(bytes,start,output,32-(bytes.size-start),bytes.size-start)
        }
        return Base64.encodeToString(byteArrayOf(4)+fixed(key.w.affineX.toByteArray())+fixed(key.w.affineY.toByteArray()),Base64.NO_WRAP)
    }
    fun sign(message:String):String {
        val signer=Signature.getInstance("SHA256withECDSA")
        signer.initSign(store().getKey(alias,null) as java.security.PrivateKey)
        signer.update(message.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(signer.sign(),Base64.NO_WRAP)
    }
}
