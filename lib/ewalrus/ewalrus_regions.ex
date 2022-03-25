defmodule Ewalrus.Regions do
  ### AWS REGIONS
  # 'us-east-1', // North Virginia
  # 'us-west-1', // North California
  # 'ap-southeast-1', // Singapore
  # 'ap-northeast-1', // Tokyo
  # 'ap-northeast-2', //Seoul
  # 'ap-southeast-2', // Sydney
  # 'eu-west-1', // Ireland
  # 'eu-west-2', // London
  # 'eu-central-1', // Frankfurt
  # 'ca-central-1', // Central Canada
  # 'ap-south-1', // Mumbai
  # 'sa-east-1', // Sao Paulo

  ### FLY REGIONS
  # {ams, "Amsterdam, Netherlands"}
  # {atl, "Atlanta, Georgia (US)"}
  # {cdg, "Paris, France"}
  # {dfw, "Dallas, Texas (US)"}
  # {ewr, "Parsippany, NJ (US)"}
  # {fra, "Frankfurt, Germany"}
  # {gru, "Sao Paulo, Brazil"}
  # {hkg, "Hong Kong"}
  # {iad, "Ashburn, Virginia (US)"}
  # {lax, "Los Angeles, California (US)"}
  # {lhr, "London, United Kingdom"}
  # {maa, "Chennai (Madras), India"}
  # {mia, "Miami, Florida (US)"}
  # {nrt, "Tokyo, Japan"}
  # {ord, "Chicago, Illinois (US)"}
  # {scl, "Santiago, Chile"}
  # {sea, "Seattle, Washington (US)"}
  # {sin, "Singapore"}
  # {sjc, "Sunnyvale, California (US)"}
  # {syd, "Sydney, Australia"}
  # {yyz, "Toronto, Canada"}

  def aws_to_fly(aws_region) do
    case aws_region do
      "us-east-1" -> ["iad", "ewr"]
      "us-west-1" -> ["sjc", "lax"]
      "ap-southeast-1" -> ["sin"]
      "ap-northeast-1" -> ["nrt"]
      "ap-northeast-2" -> ["nrt"]
      "ap-southeast-2" -> ["syd"]
      "eu-west-2" -> ["lhr"]
      "eu-central-1" -> ["fra", "cdg", "ams"]
      "ca-central-1" -> ["yyz", "ord"]
      "ap-south-1" -> ["maa"]
      "sa-east-1" -> ["gru"]
      _ -> [nil]
    end
  end
end
