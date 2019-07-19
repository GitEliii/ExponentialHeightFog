﻿Shader "Fog/ExponentialHeightFog"
{
    Properties
    {
        _MainTex ("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Tags { "RenderType"="Opaque" }
        LOD 100

        pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag

            #include "UnityCG.cginc"

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
				float4 vertex : SV_POSITION;

                float2 uv : TEXCOORD0;
				float4 fogData : TEXCOORD1; // xyz : fog color, w : transparency
            };

			// unity not support struct
			//struct Fog {
				// x : FogDensity * exp2(-FogHeightFalloff * (CameraWorldPosition.z - FogHeight))
				// y : FogHeightFalloff
				// [useless] z : CosTerminatorAngle
				// w : StartDistance
				float4 ExponentialFogParameters;

				// FogDensitySecond * exp2(-FogHeightFalloffSecond * (CameraWorldPosition.z - FogHeightSecond))
				// FogHeightFalloffSecond
				// FogDensitySecond
				// FogHeightSecond
				//[second]float4 ExponentialFogParameters2;

				// FogDensity in x
				// FogHeight in y
				// [useless] whether to use cubemap fog color in z
				// FogCutoffDistance in w
				float4 ExponentialFogParameters3;

				// xyz : directinal inscattering color
				// w : cosine exponent
				float4 DirectionalInscatteringColor;

				// xyz : directional light's direction. 方向光照射方向的反方向
				// w : direactional inscattering start distance
				float4 InscatteringLightDirection;

				// xyz : fog inscattering color
				// w : min transparency
				float4 ExponentialFogColorParameter;
			//};

			static const float FLT_EPSILON2 = 0.01f;

			sampler2D _MainTex;
			float4 _MainTex_ST;

			float Pow2(float x) { return x * x; }

			// UE 4.22 HeightFogCommon.ush
			// Calculate the line integral of the ray from the camera to the receiver position through the fog density function
			// The exponential fog density function is d = GlobalDensity * exp(-HeightFalloff * z)
			float CalculateLineIntegralShared(float FogHeightFalloff, float RayDirectionZ, float RayOriginTerms)
			{
				float Falloff = max(-127.0f, FogHeightFalloff * RayDirectionZ);    // if it's lower than -127.0, then exp2() goes crazy in OpenGL's GLSL.
				float LineIntegral = (1.0f - exp2(-Falloff)) / Falloff;
				float LineIntegralTaylor = log(2.0) - (0.5 * Pow2(log(2.0))) * Falloff;		// Taylor expansion around 0

				return RayOriginTerms * (abs(Falloff) > FLT_EPSILON2 ? LineIntegral : LineIntegralTaylor);
			}

			// UE 4.22 HeightFogCommon.ush
			// @param WorldPositionRelativeToCamera = WorldPosition - InCameraPosition
			half4 GetExponentialHeightFog(float3 WorldPositionRelativeToCamera) // camera to vertex
			{
				const half MinFogOpacity = ExponentialFogColorParameter.w;

				// Receiver 指着色点
				float3 CameraToReceiver = WorldPositionRelativeToCamera;
				float CameraToReceiverLengthSqr = dot(CameraToReceiver, CameraToReceiver);
				float CameraToReceiverLengthInv = rsqrt(CameraToReceiverLengthSqr); // 平方根的倒数
				float CameraToReceiverLength = CameraToReceiverLengthSqr * CameraToReceiverLengthInv;
				half3 CameraToReceiverNormalized = CameraToReceiver * CameraToReceiverLengthInv;

				// FogDensity * exp2(-FogHeightFalloff * (CameraWorldPosition.z - FogHeight))
				float RayOriginTerms = ExponentialFogParameters.x;
				//[second]float RayOriginTermsSecond = ExponentialFogParameters2.x;
				float RayLength = CameraToReceiverLength;
				float RayDirectionZ = CameraToReceiver.z;

				// Factor in StartDistance
				// ExponentialFogParameters.w 是 StartDistance
				float ExcludeDistance = ExponentialFogParameters.w;

				if (ExcludeDistance > 0)
				{
					// 到相交点所占时间
					float ExcludeIntersectionTime = ExcludeDistance * CameraToReceiverLengthInv;
					// 相机到相交点的 z 偏移
					float CameraToExclusionIntersectionZ = ExcludeIntersectionTime * CameraToReceiver.z;
					// 相交点的 z 坐标
					float ExclusionIntersectionZ = _WorldSpaceCameraPos.z + CameraToExclusionIntersectionZ;
					// 相交点到着色点的 z 偏移
					float ExclusionIntersectionToReceiverZ = CameraToReceiver.z - CameraToExclusionIntersectionZ;

					// Calculate fog off of the ray starting from the exclusion distance, instead of starting from the camera
					// 相交点到着色点的距离
					RayLength = (1.0f - ExcludeIntersectionTime) * CameraToReceiverLength;
					// 相交点到着色点的 z 偏移
					RayDirectionZ = ExclusionIntersectionToReceiverZ;
					// ExponentialFogParameters.y : height falloff
					// ExponentialFogParameters3.y ： fog height
					// height falloff * height
					float Exponent = max(-127.0f, ExponentialFogParameters.y * (ExclusionIntersectionZ - ExponentialFogParameters3.y));
					// ExponentialFogParameters3.x : fog density
					RayOriginTerms = ExponentialFogParameters3.x * exp2(-Exponent);

					// ExponentialFogParameters2.y : FogHeightFalloffSecond
					// ExponentialFogParameters2.w : fog height second
					//[second]float ExponentSecond = max(-127.0f, ExponentialFogParameters2.y * (ExclusionIntersectionZ - ExponentialFogParameters2.w));
					//[second]RayOriginTermsSecond = ExponentialFogParameters2.z * exp2(-ExponentSecond);
				}

				// Calculate the "shared" line integral (this term is also used for the directional light inscattering) by adding the two line integrals together (from two different height falloffs and densities)
				// ExponentialFogParameters.y : fog height falloff
				float ExponentialHeightLineIntegralShared = CalculateLineIntegralShared(ExponentialFogParameters.y, RayDirectionZ, RayOriginTerms);
					//[second]+ CalculateLineIntegralShared(ExponentialFogParameters2.y, RayDirectionZ, RayOriginTermsSecond);
				// fog amount，最终的积分值
				float ExponentialHeightLineIntegral = ExponentialHeightLineIntegralShared * RayLength;

				// 雾色
				half3 InscatteringColor = ExponentialFogColorParameter.xyz;
				half3 DirectionalInscattering = 0;

				// if InscatteringLightDirection.w is negative then it's disabled, otherwise it holds directional inscattering start distance
				if (InscatteringLightDirection.w >= 0)
				{
					float DirectionalInscatteringStartDistance = InscatteringLightDirection.w;
					// Setup a cosine lobe around the light direction to approximate inscattering from the directional light off of the ambient haze;
					half3 DirectionalLightInscattering = DirectionalInscatteringColor.xyz * pow(saturate(dot(CameraToReceiverNormalized, InscatteringLightDirection.xyz)), DirectionalInscatteringColor.w);
					
					// Calculate the line integral of the eye ray through the haze, using a special starting distance to limit the inscattering to the distance
					float DirExponentialHeightLineIntegral = ExponentialHeightLineIntegralShared * max(RayLength - DirectionalInscatteringStartDistance, 0.0f);
					// Calculate the amount of light that made it through the fog using the transmission equation
					half DirectionalInscatteringFogFactor = saturate(exp2(-DirExponentialHeightLineIntegral));
					// Final inscattering from the light
					DirectionalInscattering = DirectionalLightInscattering * (1 - DirectionalInscatteringFogFactor);
				}

				// Calculate the amount of light that made it through the fog using the transmission equation
				// 最终的系数
				half ExpFogFactor = max(saturate(exp2(-ExponentialHeightLineIntegral)), MinFogOpacity);

				// ExponentialFogParameters3.w : FogCutoffDistance
				if (ExponentialFogParameters3.w > 0 && CameraToReceiverLength > ExponentialFogParameters3.w)
				{
					ExpFogFactor = 1;
					DirectionalInscattering = 0;
				}

				half3 FogColor = (InscatteringColor) * (1 - ExpFogFactor) + DirectionalInscattering;

				return half4(FogColor, ExpFogFactor);
			}
			
            v2f vert (appdata v)
            {
                v2f o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = TRANSFORM_TEX(v.uv, _MainTex);

				// WorldSpaceViewDir : vertex to camera
				// GetHeightExponentialFog need camera to vertex
				o.fogData = GetExponentialHeightFog(-WorldSpaceViewDir(v.vertex));

                return o;
            }

            fixed4 frag (v2f IN) : SV_Target
            {
                fixed4 col = tex2D(_MainTex, IN.uv);
				return fixed4(col.xyz * IN.fogData.w + IN.fogData.xyz, col.w);
            }
            ENDCG
        }
    }
}
